Config = require '../config'
MarketPlaceStockUpdater = require('../main').MarketPlaceStockUpdater
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach (done) ->
    @updater = new MarketPlaceStockUpdater Config, Config.config.project_key, Config.config.client_id, Config.config.client_secret

    delInventory = (id) =>
      deferred = Q.defer()
      @updater.rest.DELETE "/inventory/#{id}", (error, response, body) ->
        if error
          deferred.reject error
        else
          if response.statusCode is 200 or response.statusCode is 404
            deferred.resolve true
          else
            deferred.reject body
      deferred.promise

    delProducts = (id, version) =>
      deferred = Q.defer()
      @updater.rest.DELETE "/products/#{id}?version=#{version}", (error, response, body) ->
        if error
          deferred.reject error
        else
          if response.statusCode is 200 or response.statusCode is 404
            deferred.resolve true
          else
            deferred.reject body
      deferred.promise

    @updater.rest.GET "/inventory?limit=0", (error, response, body) =>
      stocks = JSON.parse(body).results
      console.log "Cleaning up #{stocks.length} inventory entries."
      dels = []
      for s in stocks
        dels.push delInventory(s.id)

      @updater.rest.GET "/products?limit=0", (error, response, body) ->
        products = JSON.parse(body).results
        console.log "Cleaning up #{stocks.length} products."
        dels = []
        for p in products
          dels.push delProducts(p.id, p.version)

        Q.all(dels).then (v) ->
          done()
        .fail (err) ->
          console.log err
          done()

  it 'do nothing', (done) ->
    @updater.run (msg) ->
      expect(msg.status).toBe true
      expect(msg.message).toBe '0 inventory entries done.'
      done()
