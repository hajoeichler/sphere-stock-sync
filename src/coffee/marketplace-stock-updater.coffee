Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{InventorySync} = require 'sphere-node-sync'
{Qutils} = require 'sphere-node-utils'

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

    # process products in retailer
    @masterClient.channels.ensure(@retailerProjectKey, CHANNEL_ROLES)
    .then (result) =>
      retailerChannel = result.body

      @retailerClient.productProjections.staged(true).sort('id').process (payload) =>
        retailerProducts = payload.body.results
        @logger?.debug "Processing #{_.size retailerProducts} retailer products"

        # create sku mapping (attribute -> sku)
        mapping = @_createSkuMap(retailerProducts)
        @logger?.debug mapping, "Mapped #{_.size mapping} SKUs for retailer products"

        currentRetailerSKUs = _.keys(mapping)
        Qutils.processList currentRetailerSKUs, (retailerSKUs) =>
          @logger?.debug "Processing #{_.size retailerSKUs} retailer SKUs"

          ieRetailer = @retailerClient.inventoryEntries.whereOperator('or')
          _.each retailerSKUs, (sku) -> ieRetailer.where("sku = \"#{sku}\"")
          ieRetailer.fetch()
          .then (result) =>
            retailerInventoryEntries = result.body.results
            @logger?.debug {entries: retailerInventoryEntries, skus: _.keys(mapping)}, "Fetched #{_.size retailerInventoryEntries} inventory entries from retailer"

            # enhance inventory entries with channel (from master)
            enhancedRetailerInventoryEntries = @_enhanceWithRetailerChannel retailerInventoryEntries, retailerChannel.id

            # map inventory entries by replacing SKUs with the masterSKU (found in variant attributes of retailer products)
            # this way we can then query those inventories from master and decide whether to update or create them
            mappedInventoryEntries = @_replaceSKUs enhancedRetailerInventoryEntries, mapping
            @logger?.debug mappedInventoryEntries, "#{_.size mappedInventoryEntries} inventory entries are ready to be processed"
            return Q() if _.size(mappedInventoryEntries) is 0

            ieMaster = @masterClient.inventoryEntries.whereOperator('or')
            _.each mappedInventoryEntries, (entry) -> ieMaster.where("sku = \"#{entry.sku}\"")
            ieMaster.fetch()
            .then (result) =>
              existingInventoryEntries = result.body.results
              @logger?.debug existingInventoryEntries, "Found #{_.size existingInventoryEntries} matching inventory entries in master"

              Q.allSettled _.map existingInventoryEntries, (entry) =>
                existingEntry = _.find mappedInventoryEntries, (e) -> e.sku is entry.sku
                @logger?.debug existingEntry, "Found existing retailer entry for master sku #{entry.sku}"
                if existingEntry?
                  sync = @inventorySync.buildActions(existingEntry, entry)
                  if sync.get()
                    @summary.toUpdate++
                    sync.update()
                  else
                    Q()
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
                  @logger?.error failures, 'Errors while syncing stock'
                Q()
        , {accumulate: false, maxParallel: 20}
      , {accumulate: false}
    .then =>
      if @summary.toUpdate is 0 and @summary.toCreate is 0
        message = 'Summary: 0 unsynced stocks, everything is fine'
      else
        message = "Summary: there were #{@summary.toUpdate + @summary.toCreate} unsynced stocks, " +
          "(#{@summary.toUpdate} were updates and #{@summary.toCreate} were new) and " +
          "#{@summary.synced} were successfully synced (#{@summary.failed} failed)"
      Q message

  _enhanceWithRetailerChannel: (inventoryEntries, channelId) ->
    _.map inventoryEntries, (entry) ->
      entry.supplyChannel =
        typeId: 'channel'
        id: channelId
      entry

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
