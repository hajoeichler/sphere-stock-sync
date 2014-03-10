_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
Rest = require('sphere-node-connect').Rest
Q = require 'q'

class MarketPlaceStockUpdater extends InventoryUpdater
  constructor: (options = {}) ->
    throw new Error 'No base configuration in options!' unless options.baseConfig
    throw new Error 'No master configuration in options!' unless options.master
    throw new Error 'No retailer configuration in options!' unless options.retailer
    super config: _.extend(options.master, options.baseConfig)
    @logger = options.baseConfig.logConfig.logger
    @retailerProjectKey = options.retailer.project_key
    @retailerRest = new Rest config: _.extend(options.retailer, options.baseConfig)
    @masterRest = @rest

  run: (callback) ->
    Q.all([
      @allInventoryEntries(@retailerRest),
      @ensureChannelByKey(@masterRest, @retailerProjectKey)
    ]).spread (retailerInventory, retailerChannel) =>
      @logger.debug "Retailer inventory entries: #{_.size retailerInventory}" if @logger
      enhancedRetailerInventory = @_enhanceWithRetailerChannel retailerInventory, retailerChannel.id

      @initMatcher().then (mapping) =>
        validInventory = @_getInventoryWithMapping enhancedRetailerInventory, mapping
        @logger.debug "Inventory entries with mapping #: #{_.size validInventory}" if @logger
        unless _.size(enhancedRetailerInventory) is _.size(validInventory)
          @logger.error "There are inventory entries we can't map to master" if @logger

        mappedInventory = @_replaceSKUs validInventory, mapping
        @createOrUpdate mappedInventory, callback

    .fail (msg) =>
      @returnResult false, msg, callback

  initMatcher: () ->
    deferred = Q.defer()
    Q.all([
      @retailerProducts()
      @allInventoryEntries(@masterRest)
    ]).spread (retailerProducts, masterInventory) =>
      if @logger
        @logger.debug "Master inventory entries: #{_.size masterInventory}"
        @logger.debug "Retailer products: #{_.size retailerProducts}"

      @existingInventoryEntries = masterInventory
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

  # TODO:
  # - get only published products
  retailerProducts: (staged = true) ->
    deferred = Q.defer()
    @retailerRest.GET "/product-projections?limit=0", (error, response, body) ->
      if error
        deferred.reject 'Error on getting retailers products: ' + error
      else if response.statusCode isnt 200
        deferred.reject 'Problem on getting retailers products: ' + error
      else
        retailerProducts = body.results
        deferred.resolve retailerProducts
    deferred.promise

module.exports = MarketPlaceStockUpdater