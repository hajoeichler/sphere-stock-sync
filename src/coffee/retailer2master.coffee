Q = require 'q'
_ = require 'underscore'
{InventoryUpdater} = require 'sphere-node-sync'
SphereClient = require 'sphere-node-client'

class MarketPlaceStockUpdater extends InventoryUpdater

  constructor: (options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer

    masterOpts = _.clone options.baseConfig
    masterOpts.config = options.master
    super masterOpts

    retailerOpts = _.clone options.baseConfig
    retailerOpts.config = options.retailer

    @masterClient = new SphereClient masterOpts
    @retailerClient = new SphereClient retailerOpts

    @logger = options.baseConfig.logConfig.logger
    @retailerProjectKey = options.retailer.project_key

    @fetchHours = options.baseConfig.fetchHours or 24

  run: (callback) ->
    Q.all([
      @allInventoryEntries(@retailerClient, 'retailer'),
      @ensureChannelByKey(@masterClient._rest, @retailerProjectKey, ['InventorySupply', 'OrderExport', 'OrderImport'])
    ]).spread (retailerInventory, retailerChannel) =>
      @logger.info "Retailer inventory entries: #{_.size retailerInventory}" if @logger
      enhancedRetailerInventory = @_enhanceWithRetailerChannel retailerInventory, retailerChannel.id

      @initMatcher().then (mapping) =>
        validInventory = @_getInventoryWithMapping enhancedRetailerInventory, mapping
        @logger.info "Inventory entries with mapping #: #{_.size validInventory}" if @logger
        unless _.size(enhancedRetailerInventory) is _.size(validInventory)
          @logger.warn "There are inventory entries we can't map to master" if @logger

        mappedInventory = @_replaceSKUs validInventory, mapping
        @createOrUpdate mappedInventory, callback
    .fail (msg) =>
      @returnResult false, msg, callback

  initMatcher: ->
    deferred = Q.defer()
    @allInventoryEntries(@masterClient, 'master')
    .then (masterInventory) =>
      @logger.debug "Master inventory entries: #{_.size masterInventory}" if @logger
      @existingInventoryEntries = masterInventory
      @retailerProducts(@retailerClient)
    .then (retailerProducts) =>
      @logger.debug "Retailer products: #{_.size retailerProducts}" if @logger
      deferred.resolve @_createSkuMap(retailerProducts)

    deferred.promise

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

  _enhanceWithRetailerChannel: (inventory, channelId) ->
    _.map inventory, (entry) ->
      entry.supplyChannel =
        typeId: 'channel'
        id: channelId
      entry

  _getInventoryWithMapping: (inventory, retailerSku2masterSku) ->
    _.select inventory, (entry) ->
      _.has(retailerSku2masterSku, entry.sku)

  _replaceSKUs: (inventory, retailerSku2masterSku) ->
    _.map inventory, (entry) ->
      entry.sku = retailerSku2masterSku[entry.sku]
      entry

  allInventoryEntries: (client, type) ->
    deferred = Q.defer()
    client.inventoryEntries.perPage(0).sort('id').fetch()
    .then (result) ->
      deferred.resolve result.results
    .fail (err) ->
      deferred.reject "Problem on getting inventory entries: #{err}"

    deferred.promise

  retailerProducts: (client)->
    deferred = Q.defer()
    client.productProjections.perPage(0).sort('id').staged().fetch()
    .then (result) ->
      deferred.resolve result.results
    .fail (err) ->
      deferred.reject "Problem on getting retailer products: #{err}"

    deferred.promise


module.exports = MarketPlaceStockUpdater
