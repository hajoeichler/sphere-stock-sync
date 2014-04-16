Q = require 'q'
_ = require 'underscore'
{Logger, _u} = require 'sphere-node-utils'
_.mixin _u
package_json = require '../package.json'
Config = require '../config'
MarketPlaceStockUpdater = require '../lib/marketplace-stock-updater'


uniqueId = (prefix) ->
  _.uniqueId "#{prefix}#{new Date().getTime()}_"

updatePublish = (version) ->
  version: version
  actions: [
    {action: 'publish'}
  ]

updateUnpublish = (version) ->
  version: version
  actions: [
    {action: 'unpublish'}
  ]

cleanup = (client, logger) ->
  logger.info 'Cleaning up...'
  logger.debug 'Deleting old inventory entries...'
  client.inventoryEntries.perPage(0).fetch()
  .then (result) ->
    Q.all _.map result.body.results, (e) ->
      client.inventoryEntries.byId(e.id).delete(e.version)
  .then (results) ->
    logger.debug "#{_.size results} deleted."
    logger.debug 'Unpublishing all products'
  client.products.sort('id').where('masterData(published = "true")').process (payload) ->
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).update(updateUnpublish(product.version))
  .then (results) ->
    logger.debug "Unpublished #{results.length} products"
    logger.debug 'About to delete all products'
    client.products.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} products"
    Q.all _.map payload.body.results, (product) ->
      client.products.byId(product.id).delete(product.version)
  .then (results) ->
    logger.debug "Deleted #{results.length} products"
    logger.debug 'About to delete all product types'
    client.productTypes.perPage(0).fetch()
  .then (payload) ->
    logger.debug "Deleting #{payload.body.total} product types"
    Q.all _.map payload.body.results, (productType) ->
      client.productTypes.byId(productType.id).delete(productType.version)
  .then (results) ->
    logger.debug "Deleted #{results.length} product types"
    Q()

describe '#run', ->

  beforeEach (done) ->
    @logger = new Logger
      name: "#{package_json.name}-#{package_json.version}:#{Config.config.project_key}"
      streams: [
        { level: 'info', stream: process.stdout }
      ]

    options =
      baseConfig:
        logConfig:
          logger: @logger
      master:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret
      retailer:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret

    @updater = new MarketPlaceStockUpdater options
    @client = @updater.masterClient

    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  afterEach (done) ->
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  it 'do nothing', (done) ->
    @updater.run()
    .then (msg) ->
      expect(msg).toBe "Nothing to sync for retailer '#{Config.config.project_key}'"
      done()
    .fail (error) -> done _.prettify error
  , 20000 # 20sec

  # workflow
  # - create a product type
  # - create a product for the master
  # - create a product for the retailer with the mastersku attribute
  # - publish retailer product
  # - create inventory item in the master with channel of retailer
  # - create inventory item in retailer
  # - run update
  # - check that master inventory is updated
  it 'sync one inventory entry', (done) ->
    mockProductType = ->
      name: uniqueId 'PT-'
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
    mockProduct = (productType) ->
      productType:
        typeId: 'product-type'
        id: productType.id
      name:
        en: uniqueId 'P-'
      slug:
        en: uniqueId 'p-'
      masterVariant:
        sku: uniqueId 'mastersku-'

    # create productType
    @client.productTypes.save(mockProductType())
    .then (result) =>
      # create 2 products
      # - for master
      # - for retailer (with mastersku attribute)
      @masterProduct = mockProduct(result.body)
      @retailerProduct = mockProduct(result.body)
      @retailerProduct.masterVariant.attributes = [
        { name: 'mastersku', value: @masterProduct.masterVariant.sku }
      ]

      @client.products.save(@masterProduct)
    .then (result) =>
      expect(result.statusCode).toBe 201
      @masterProduct = result.body
      @logger.debug @masterProduct, 'Master product created'
      @client.products.save(@retailerProduct)
    .then (result) =>
      expect(result.statusCode).toBe 201
      @retailerProduct = result.body
      @logger.debug @retailerProduct, 'Retailer product created'
      @client.products.byId(@retailerProduct.id).update(updatePublish(@retailerProduct.version))
    .then (result) =>
      expect(result.statusCode).toBe 200
      @retailerProduct = result.body
      @logger.debug @retailerProduct, 'Retailer product published'
      @client.channels.ensure(Config.config.project_key, 'InventorySupply')
    .then (result) =>
      expect(result.statusCode).toBe 200
      @retailerSku = @retailerProduct.masterData.current.masterVariant.sku
      @masterSku = @masterProduct.masterData.staged.masterVariant.sku
      retailerEntry =
        sku: @retailerSku
        quantityOnStock: 3
      masterEntry =
        sku: @masterSku
        quantityOnStock: 7
        supplyChannel:
          typeId: 'channel'
          id: result.body.id

      Q.all [@client.inventoryEntries.save(retailerEntry), @client.inventoryEntries.save(masterEntry)]
    .then (results) =>
      expect(results[0].statusCode).toBe 201
      expect(results[1].statusCode).toBe 201

      @updater.run()
    .then (msg) =>
      expect(msg).toBe "Summary for retailer '#{Config.config.project_key}': 1 were updated, 0 were created."

      @client.inventoryEntries.where("sku = \"#{@masterSku}\"").fetch()
    .then (results) ->
      expect(results.statusCode).toBe 200
      expect(results.body.results[0].quantityOnStock).toBe 3
      done()
    .fail (error) -> done _.prettify error
  , 60000 # 1min
