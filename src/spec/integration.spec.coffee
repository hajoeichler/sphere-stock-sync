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
      expect(msg.message).toBe 'Nothing to do.'
      done()

  it 'sync one inventory entry', (done) ->
    unique = new Date().getTime()
    pt =
      name: "PT-#{unique}"
      description: 'bla'
      attributes: [{
        name: 'mastersku'
        label:
          de: 'Master SKU'
        type: 'text'
        isVariant: true
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
          ie =
            sku: "mastersku-#{unique}"
            quantityOnStock: 3
          @updater.ensureChannelByKey(@updater.rest, Config.config.project_key).then (channel) =>
            @updater.rest.POST "/inventory", JSON.stringify(ie), (error, response, body) =>
              expect(response.statusCode).toBe 201
              ie =
                sku: "retailer-#{unique}"
                quantityOnStock: 7
                channel:
                  typeId: 'channel'
                  id: channel.id
              @updater.rest.POST "/inventory", JSON.stringify(ie), (error, response, body) =>
                expect(response.statusCode).toBe 201
                @updater.run (msg) =>
                  expect(msg.status).toBe true
                  expect(msg.message.length).toBe 2
                  expect(msg.message[0]).toBe "The updater will not create new inventory entry. sku: mastersku-#{unique}"
                  expect(msg.message[1]).toBe 'Inventory entry updated.'
                  @updater.rest.GET "/inventory?where=sku%3D%22mastersku-#{unique}%22", (error, response, body) ->
                    expect(response.statusCode).toBe 200
                    entries = JSON.parse(body).results
                    expect(entries[0].quantityOnStock).toBe 7
                    done()