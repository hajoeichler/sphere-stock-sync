_ = require('underscore')._
Config = require '../config'
MarketPlaceStockUpdater = require '../lib/retailer2master'
Q = require 'q'

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
      expect(msg.message).toBe 'Nothing to do.'
      done()

  # workflow
  # - create a product type
  # - create a product for the master
  # - create a product for the retailer with the mastersku attribute
  # - create inventory item in the master with channel of retailer
  # - create inventory item in retailer
  # - run update
  # - check that master inventory is updated
  it 'sync one inventory entry', (done) ->
    unique = new Date().getTime()
    pt =
      name: "PT-#{unique}"
      description: 'bla'
      attributes: [{
        name: 'mastersku'
        label:
          de: 'Master SKU'
        type:
          name: 'text'
        isRequired: false
        inputHint: 'SingleLine'
      }]
    @updater.rest.POST '/product-types', JSON.stringify(pt), (error, response, body) =>
      expect(response.statusCode).toBe 201
      pt = JSON.parse(body)
      p =
        productType:
          typeId: 'product-type'
          id: pt.id
        name:
          en: "P-#{unique}"
        slug:
          en: "p-#{unique}"
        masterVariant:
          sku: "mastersku-#{unique}"
      @updater.rest.POST "/products", JSON.stringify(p), (error, response, body) =>
        expect(response.statusCode).toBe 201
        p.slug.en = "p-#{unique}1"
        p.masterVariant.sku = "retailer-#{unique}"
        p.masterVariant.attributes = [
          { name: 'mastersku', value: "mastersku-#{unique}" }
        ]
        @updater.rest.POST "/products", JSON.stringify(p), (error, response, body) =>
          expect(response.statusCode).toBe 201
          entry =
            sku: "retailer-#{unique}"
            quantityOnStock: 3
          @updater.ensureChannelByKey(@updater.rest, Config.config.project_key).then (retailerChannel) =>
            @updater.rest.POST "/inventory", JSON.stringify(entry), (error, response, body) =>
              expect(response.statusCode).toBe 201
              entry =
                sku: "mastersku-#{unique}"
                quantityOnStock: 7
                supplyChannel:
                  typeId: 'channel'
                  id: retailerChannel.id
              @updater.rest.POST "/inventory", JSON.stringify(entry), (error, response, body) =>
                expect(response.statusCode).toBe 201
                @updater.run (msg) =>
                  expect(msg.status).toBe true
                  expect(msg.message).toBe 'Inventory entry updated.'
                  @updater.rest.GET "/inventory?where=sku%3D%22mastersku-#{unique}%22", (error, response, body) ->
                    expect(response.statusCode).toBe 200
                    entries = JSON.parse(body).results
                    expect(entries[0].quantityOnStock).toBe 3
                    done()