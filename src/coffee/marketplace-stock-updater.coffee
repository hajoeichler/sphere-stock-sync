Q = require 'q'
_ = require 'underscore'
SphereClient = require 'sphere-node-client'
{InventorySync} = require 'sphere-node-sync'

CHANNEL_REF_NAME = 'supplyChannel'

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
    @existingInventoryEntries = {}

  run: (callback) ->
    @logger?.debug "Running stock-sync for retailer '#{@retailerProjectKey}'"
    Q.all([
      @retailerClient.inventoryEntries.perPage(0).sort('id').fetch()
      @masterClient.channels.ensure(@retailerProjectKey, ['InventorySupply', 'OrderExport', 'OrderImport'])
    ]).spread (allRetInvResults, chResult) =>
      retailerInventoryEntries = allRetInvResults.body.results
      retailerChannel = chResult.body

      @logger?.debug "Fetched #{_.size retailerInventoryEntries} inventory entries from retailer '#{@retailerProjectKey}'"
      enhancedRetailerInventoryEntries = @_enhanceWithRetailerChannel retailerInventoryEntries, retailerChannel.id

      @masterClient.inventoryEntries.perPage(0).sort('id').fetch()
      .then (allInvResults) =>
        masterInventoryEntries = allInvResults.body.results
        @logger?.debug "Fetched #{_.size masterInventoryEntries} inventory entries from master"
        @existingInventoryEntries = masterInventoryEntries

        @retailerClient.productProjections.perPage(0).sort('id').staged().fetch()
      .then (allRetProdResults) =>
        allRetailerProducts = allRetProdResults.body.results
        @logger?.debug "Fetched #{_.size allRetailerProducts} products from retailer '#{@retailerProjectKey}'"
        mapping = @_createSkuMap(allRetailerProducts)
        validInventoryEntries = @_getInventoryWithMapping enhancedRetailerInventoryEntries, mapping
        @logger?.debug "Mapped #{_.size validInventoryEntries} inventory entries"

        unless _.size(enhancedRetailerInventoryEntries) is _.size(validInventoryEntries)
          @logger.warn "There are inventory entries we can't map to master for retailer '#{@retailerProjectKey}'"

        mappedInventoryEntries = @_replaceSKUs validInventoryEntries, mapping

        return Q("Nothing to sync for retailer '#{@retailerProjectKey}'") if _.size(mappedInventoryEntries) is 0

        stats =
          toUpdate: 0
          toCreate: 0
        Q.all _.map mappedInventoryEntries, (entry) =>
          existingEntry = @_match(entry)
          if existingEntry?
            stats.toUpdate += 1
            @inventorySync.buildActions(entry, existingEntry).update()
          else
            stats.toCreate += 1
            @masterClient.inventoryEntries.save(entry)
        .then => Q "Summary for retailer '#{@retailerProjectKey}': #{stats.toUpdate} were updated, #{stats.toCreate} were created."


  _match: (entry) ->
    _.find @existingInventoryEntries, (existingEntry) ->
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

  _getInventoryWithMapping: (inventoryEntries, retailerSku2masterSku) ->
    _.select inventoryEntries, (entry) ->
      _.has(retailerSku2masterSku, entry.sku)

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
