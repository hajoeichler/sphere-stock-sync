Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{InventorySync} = require 'sphere-node-sync'

CHANNEL_REF_NAME = 'supplyChannel'
CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

class MarketPlaceStockUpdater

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master

    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @inventorySync = new InventorySync masterOpts
    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @retailerProjectKey = options.retailer.project_key
    @fetchHours = options.baseConfig.fetchHours or 24
    @_resetSummary()

  _resetSummary: ->
    @summary =
      toUpdate: 0
      toCreate: 0
      synced: 0
      failed: 0

  run: (callback) ->
    @_resetSummary()

    @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
    .then (result) =>
      retailerChannel = result.body

      # process products in retailer
      @retailerClient.productProjections.sort('id').staged(true).process (payload) =>
        retailerProducts = payload.body.results
        @logger?.debug "Fetched #{_.size retailerProducts} products from retailer"

        # create sku mapping (attribute -> sku)
        mapping = @_createSkuMap(retailerProducts)
        @logger?.debug mapping, 'Mapped SKUs for retailer products'

        # fetch retailer inventory entries
        @retailerClient.inventoryEntries.sort('id').process (inventoryRetailerPayload) =>
          retailerInventoryEntries = inventoryRetailerPayload.body.results
          @logger?.debug "Fetched #{_.size retailerInventoryEntries} inventories from retailer"

          # enhance inventory entries with channel (from master)
          enhancedRetailerInventoryEntries = @_enhanceWithRetailerChannel retailerInventoryEntries, retailerChannel.id
          @logger?.debug enhancedRetailerInventoryEntries, 'Retailer inventory entries enhanced with channel from master'

          # validate inventory entries based on SKU mapping
          [validInventoryEntries, notValidInventoryEntries] = _.partition enhancedRetailerInventoryEntries, (entry) =>
            @_validateInventoryWithMapping entry, mapping
          @logger?.debug validInventoryEntries, "There are #{_.size validInventoryEntries} valid inventory entries"

          if _.size(notValidInventoryEntries) > 0
            @logger.warn notValidInventoryEntries, "There are inventory entries we can't map to master SKUs"

          # replace SKUs
          mappedInventoryEntries = @_replaceSKUs validInventoryEntries, mapping

          return Q() if _.size(mappedInventoryEntries) is 0

          # time to fetch inventory entries from master and update stuff
          @masterClient.inventoryEntries.sort('id').process (inventoryMasterPayload) =>
            masterInventoryEntries = inventoryMasterPayload.body.results
            @logger?.debug "Fetched #{_.size masterInventoryEntries} inventories from retailer"

            Q.allSettled _.map mappedInventoryEntries, (entry) =>
              existingEntry = @_match(entry, masterInventoryEntries)
              if existingEntry?
                @summary.toUpdate++
                @inventorySync.buildActions(entry, existingEntry).update()
              else
                @summary.toCreate++
                @masterClient.inventoryEntries.save(entry)
            .then (results) =>
              failures = []
              _.each results, (result) =>
                if result.state is 'fulfilled'
                  @summary.synced++
                else
                  @summary.failed++
                  failures.push result.reason
              if _.size(failures) > 0
                @logger.error failures, 'Errors while syncing stock'
              Q()
    .then =>
      if @summary.toUpdate is 0 and @summary.toCreate is 0
        message = 'Summary: 0 unsynced stocks, everything is fine'
      else
        message = "Summary: there were #{@summary.toUpdate + @summary.toCreate} unsynced stocks, " +
          "(#{@summary.toUpdate} were updates and #{@summary.toCreate} were new) and " +
          "#{@summary.synced} were successfully synced (#{@summary.failed} failed)"
      Q message

  _match: (entry, existingInventoryEntries) ->
    _.find existingInventoryEntries, (existingEntry) ->
      if existingEntry.sku is entry.sku
        if _.has(existingEntry, CHANNEL_REF_NAME) and _.has(entry, CHANNEL_REF_NAME)
          existingEntry[CHANNEL_REF_NAME].id is entry[CHANNEL_REF_NAME].id
        else
          not _.has(entry, CHANNEL_REF_NAME)

  _enhanceWithRetailerChannel: (inventoryEntries, channelId) ->
    _.map inventoryEntries, (entry) ->
      entry.supplyChannel =
        typeId: 'channel'
        id: channelId
      entry

  _validateInventoryWithMapping: (entry, mapping) -> _.has(mapping, entry.sku)

  _replaceSKUs: (inventoryEntries, retailerSku2masterSku) ->
    _.map inventoryEntries, (entry) ->
      entry.sku = retailerSku2masterSku[entry.sku]
      entry

  _createSkuMap: (products) ->
    retailerSku2masterSku = {}
    _.each products, (product) =>
      product.variants or= []
      variants = [product.masterVariant].concat(product.variants)
      _.each variants, (variant) =>
        r2m = @_matchVariant(variant)
        _.extend(retailerSku2masterSku, r2m)

    retailerSku2masterSku

  _matchVariant: (variant) ->
    retailerSku = variant.sku
    return {} unless retailerSku
    return {} unless variant.attributes
    attribute = _.find variant.attributes, (attribute) ->
      attribute.name is 'mastersku'
    return {} unless attribute
    masterSku = attribute.value
    return {} unless masterSku
    r2m = {}
    r2m[retailerSku] = masterSku

    r2m

module.exports = MarketPlaceStockUpdater
