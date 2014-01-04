_ = require('underscore')._
InventoryUpdater = require('sphere-node-sync').InventoryUpdater
Rest = require('sphere-node-connect').Rest
Q = require 'q'

class MarketPlaceStockUpdater extends InventoryUpdater
  constructor: (@options, @retailerProjectKey, @retailerClientId, @retailerClientSecret) ->
    super @options
    cfg =
      project_key: @retailerProjectKey
      client_id: @retailerClientId
      client_secret: @retailerClientSecret
    @retailerRest = new Rest config: cfg

  run: (callback) ->
    @allInventoryEntries(@retailerRest).then (retailerStock) =>
      @initMatcher().then (sku2index) =>
        @sku2index = sku2index
        @createOrUpdate retailerStock, callback
      .fail (msg)->
        @returnResult false, msg, callback
    .fail (msg)->
      @returnResult false, msg, callback

  initMatcher: () ->
    deferred = Q.defer()
    Q.all([@retailerProducts(), @allInventoryEntries(@rest)])
    .then ([retailerProducts, masterStocks]) =>
      @existingInventoryEntries = masterStocks

      master2retailer = {}
      for p in retailerProducts
        _.extend(master2retailer, @matchVariant(p.masterData.current.masterVariant))
        for v in p.masterData.current.variants
          _.extend(master2retailer, @matchVariant(v))

      sku2index = {}
      for es, i in masterStocks
        rSku = master2retailer[es.sku]
        continue if not rSku
        sku2index[rSku] = i

      deferred.resolve sku2index
    .fail (msg) ->
      deferred.reject msg
    deferred.promise

  retailerProducts: () ->
    deferred = Q.defer()
    @retailerRest.GET "/products?limit=0", (error, response, body) ->
      if error
        deferred.reject 'Error on getting retailers products: ' + error
      else if response.statusCode isnt 200
        deferred.reject 'Problem on getting retailers products: ' + error
      else
        retailerProducts = JSON.parse(body).results
        deferred.resolve retailerProducts
    deferred.promise

  matchVariant: (variant) ->
    m2r = {}
    rSku = variant.sku
    return m2r if not rSku
    for a in variant.attributes
      continue if a.name isnt 'mastersku'
      mSku = a.value
      return m2r if not mSku
      m2r[mSku] = rSku
      break
    m2r

  create: (stock) ->
    # We don't create new stock entries for now - only update existing!
    # Idea: create stock only for entries that have a product that have a valid mastersku set
    deferred = Q.defer()
    @bar.tick() if @bar
    deferred.resolve 'The updater will not create new inventory entry. sku: ' + stock.sku
    deferred.promise

module.exports = MarketPlaceStockUpdater