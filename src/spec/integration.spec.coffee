Q = require 'q'
_ = require 'underscore'
Config = require '../config'
Logger = require '../lib/logger'
MarketPlaceStockUpdater = require '../lib/retailer2master'

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach (done) ->
    options =
      baseConfig:
        logConfig:
          logger: new Logger()
      master:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret
      retailer:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret

    @updater = new MarketPlaceStockUpdater options

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
          if response.statusCode is 200 or response.statusCode is 400
            deferred.resolve true
          else
            deferred.reject body
      deferred.promise

    @updater.retailerClient.inventoryEntries.perPage(0).fetch()
    .then (result) =>
      console.log "Cleaning up #{_.size result.results} inventory entries."
      dels = _.map result.results, (e) -> delInventory e.id

      @updater.retailerClient.products.perPage(0).fetch()
    .then (result) ->
      console.log "Cleaning up #{_.size result.results} products."
      dels = _.map result.results, (p) -> delProducts p.id, p.version

      Q.all(dels)
    .then (v) -> done()
    .fail (error) -> done(error)

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
    productType =
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
    @updater.rest.POST '/product-types', productType, (error, response, body) =>
      expect(response.statusCode).toBe 201
      product =
        productType:
          typeId: 'product-type'
          id: body.id
        name:
          en: "P-#{unique}"
        slug:
          en: "p-#{unique}"
        masterVariant:
          sku: "mastersku-#{unique}"
      @updater.rest.POST "/products", product, (error, response, body) =>
        expect(response.statusCode).toBe 201
        product.slug.en = "p-#{unique}1"
        product.masterVariant.sku = "retailer-#{unique}"
        product.masterVariant.attributes = [
          { name: 'mastersku', value: "mastersku-#{unique}" }
        ]
        @updater.rest.POST "/products", product, (error, response, body) =>
          expect(response.statusCode).toBe 201
          data =
            actions: [
              { action: 'publish' }
            ]
            version: body.version
          @updater.rest.POST "/products/#{body.id}", data, (error, response, body) =>
            expect(response.statusCode).toBe 200
            entry =
              sku: "retailer-#{unique}"
              quantityOnStock: 3
            @updater.ensureChannelByKey(@updater.rest, Config.config.project_key).then (retailerChannel) =>
              @updater.rest.POST "/inventory", entry, (error, response, body) =>
                expect(response.statusCode).toBe 201
                entry =
                  sku: "mastersku-#{unique}"
                  quantityOnStock: 7
                  supplyChannel:
                    typeId: 'channel'
                    id: retailerChannel.id
                @updater.rest.POST "/inventory", entry, (error, response, body) =>
                  expect(response.statusCode).toBe 201
                  @updater.run (msg) =>
                    expect(msg.status).toBe true
                    expect(msg.message).toBe 'Inventory entry updated.'
                    @updater.rest.GET "/inventory?where=sku%3D%22mastersku-#{unique}%22", (error, response, body) ->
                      expect(response.statusCode).toBe 200
                      entries = body.results
                      expect(entries[0].quantityOnStock).toBe 3
                      done()