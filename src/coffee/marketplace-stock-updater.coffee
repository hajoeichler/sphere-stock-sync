_ = require 'underscore'
_.mixin require 'underscore-mixins'
Promise = require 'bluebird'
{SphereClient, InventorySync, TaskQueue} = require 'sphere-node-sdk'

CHANNEL_REF_NAME = 'supplyChannel'
CHANNEL_ROLES = ['InventorySupply', 'OrderExport', 'OrderImport']

class MarketPlaceStockUpdater

  constructor: (@logger, options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    @inventorySync = new InventorySync
    globalTaskQueue = new TaskQueue

    @masterClient = new SphereClient _.extend {}, _.deepClone(options.baseConfig),
      config: options.master
      task: globalTaskQueue

    @retailerClient = new SphereClient _.extend {}, _.deepClone(options.baseConfig),
      config: options.retailer
      task: globalTaskQueue

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

      # fetch inventories from last X hours
      @retailerClient.inventoryEntries.last("#{@fetchHours}h").perPage(10).process (payload) =>
        retailerInventoryEntries = payload.body.results
        @logger?.debug retailerInventoryEntries, "About to process #{_.size retailerInventoryEntries} retailer inventory entries"

        # fetch corresponding products for sku mapping
        retailerProducts = @retailerClient.productProjections.staged(true).all().whereOperator('or')
        _.each retailerInventoryEntries, (stock) ->
          retailerProducts.where("masterVariant(sku = \"#{stock.sku}\") or variants(sku = \"#{stock.sku}\")")
        retailerProducts.fetch()
        .then (result) =>
          matchedRetailerProductsBySku = result.body.results
          @logger?.debug matchedRetailerProductsBySku, 'Matched retailer products by sku'
          # create sku mapping (attribute -> sku)
          mapping = @_createSkuMap(matchedRetailerProductsBySku)
          @logger?.debug mapping, "Mapped #{_.size mapping} SKUs for retailer products"

          # enhance inventory entries with channel (from master)
          enhancedRetailerInventoryEntries = @_enhanceWithRetailerChannel retailerInventoryEntries, retailerChannel.id
          @logger?.debug enhancedRetailerInventoryEntries, "Enhanced inventory entries witch retailer channel #{retailerChannel.id}"

          # map inventory entries by replacing SKUs with the masterSKU (found in variant attributes of retailer products)
          # this way we can then query those inventories from master and decide whether to update or create them
          mappedInventoryEntries = @_replaceSKUs enhancedRetailerInventoryEntries, mapping
          @logger?.debug mappedInventoryEntries, "#{_.size mappedInventoryEntries} inventory entries are ready to be processed"
          # IMPORTANT: since some inventories may not be mapped to a masterSku
          # we should simply discard them since they do not need to be sync to master
          mappendInventoryEntriesWithMasterSkuOnly = _.filter mappedInventoryEntries, (e) -> e.sku
          return Promise.resolve() if _.size(mappendInventoryEntriesWithMasterSkuOnly) is 0

          ieMasterSkus = _.map mappendInventoryEntriesWithMasterSkuOnly, (entry) -> "\"#{entry.sku}\""
          ieMasterPredicate = "sku in (#{ieMasterSkus.join(', ')})"

          @masterClient.inventoryEntries.all().where(ieMasterPredicate).fetch()
          .then (result) =>
            existingEntriesInMaster = result.body.results
            @logger?.debug existingEntriesInMaster, "Found #{_.size existingEntriesInMaster} matching inventory entries in master"

            Promise.settle _.map mappendInventoryEntriesWithMasterSkuOnly, (retailerEntry) =>
              masterEntry = _.find existingEntriesInMaster, (e) -> e.sku is retailerEntry.sku
              if masterEntry?
                @logger?.debug masterEntry, "Found existing inventory entry in master for sku #{retailerEntry.sku}, about to build update actions"
                synced = @inventorySync.buildActions(retailerEntry, masterEntry)
                if synced.shouldUpdate()
                  @summary.toUpdate++
                  @masterClient.inventoryEntries.byId(synced.getUpdateId()).update(synced.getUpdatePayload())
                else
                  @logger?.debug masterEntry, "No update necessary for entry in master with sku #{retailerEntry.sku}"
                  Promise.resolve()
              else
                @logger?.debug "No inventory entry found in master for sku #{retailerEntry.sku}, about to create it"
                @summary.toCreate++
                @masterClient.inventoryEntries.save(retailerEntry)
            .then (results) =>
              failures = []
              _.each results, (result) =>
                if result.isFulfilled()
                  @summary.synced++
                else
                  @summary.failed++
                  failures.push result.reason()
              if _.size(failures) > 0
                @logger?.error failures, 'Errors while syncing stock'
              Promise.resolve()
      , {accumulate: false}
    .then =>
      if @summary.toUpdate is 0 and @summary.toCreate is 0
        message = 'Summary: 0 unsynced stocks, everything is fine'
      else
        message = "Summary: there were #{@summary.toUpdate + @summary.toCreate} unsynced stocks, " +
          "(#{@summary.toUpdate} were updates and #{@summary.toCreate} were new) and " +
          "#{@summary.synced} were successfully synced (#{@summary.failed} failed)"
      Promise.resolve message

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
