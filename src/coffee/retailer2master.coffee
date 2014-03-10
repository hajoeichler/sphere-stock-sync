_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
Rest = require('sphere-node-connect').Rest
Q = require 'q'

class MarketPlaceStockUpdater extends InventoryUpdater
  constructor: (options, retailerProjectKey, retailerClientId, retailerClientSecret) ->
    super options
    @retailerProjectKey = retailerProjectKey
    cfg =
      project_key: retailerProjectKey
      client_id: retailerClientId
      client_secret: retailerClientSecret
    @retailerRest = new Rest config: cfg

  run: (callback) ->
    Q.all([
      @allInventoryEntries(@retailerRest),
      @ensureChannelByKey(@rest, @retailerProjectKey)
    ]).spread (retailerInventory, retailerChannel) =>
      enhancedRetailerInventory = @_enhanceWithRetailerChannel retailerInventory, retailerChannel.id

      @initMatcher().then (mapping) =>
        validInventory = @_getInventoryWithMapping enhancedRetailerInventory, mapping
        unless _.size(enhancedRetailerInventory) is _.size(validInventory)
          console.error "There are inventory entries we can't map to master"

        mappedInventory = @_replaceSKUs validInventory, mapping
        @createOrUpdate mappedInventory, callback

    .fail (msg) =>
      @returnResult false, msg, callback

  initMatcher: () ->
    deferred = Q.defer()
    Q.all([
      @retailerProducts()
      @allInventoryEntries(@rest)
    ]).spread (retailerProducts, masterInventory) =>
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
  # - get in batches
  # - get only published products
  retailerProducts: (staged = true) ->
    deferred = Q.defer()
    @retailerRest.GET "/product-projections?staged=#{staged}&limit=0", (error, response, body) ->
      if error
        deferred.reject 'Error on getting retailers products: ' + error
      else if response.statusCode isnt 200
        deferred.reject 'Problem on getting retailers products: ' + error
      else
        retailerProducts = body.results
        deferred.resolve retailerProducts
    deferred.promise

  # TODO: remove!
  create: (stock) ->
    # We don't create new stock entries for now - only update existing!
    # Idea: create stock only for entries that have a product that have a valid mastersku set
    deferred = Q.defer()
    @tickProgress()
    deferred.resolve 'The updater will not create new inventory entry. sku: ' + stock.sku
    deferred.promise

module.exports = MarketPlaceStockUpdater