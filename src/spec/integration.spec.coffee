Q = require 'q'
_ = require 'underscore'
_.mixin require('sphere-node-utils')._u
{ExtendedLogger} = require 'sphere-node-utils'
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
    @logger = new ExtendedLogger
      additionalFields:
        project_key: Config.config.project_key
      logConfig:
        name: "#{package_json.name}-#{package_json.version}"
        streams: [
          { level: 'info', stream: process.stdout }
        ]

    options =
      baseConfig:
        logConfig:
          logger: @logger.bunyanLogger
      master:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret
      retailer:
        project_key: Config.config.project_key
        client_id: Config.config.client_id
        client_secret: Config.config.client_secret

    @updater = new MarketPlaceStockUpdater @logger, options
    @client = @updater.masterClient

    @logger.info 'About to setup...'
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  afterEach (done) ->
    @logger.info 'About to cleanup...'
    cleanup(@client, @logger)
    .then -> done()
    .fail (error) -> done _.prettify error
  , 30000 # 30sec

  it 'do nothing', (done) ->
    @updater.run()
    .then (msg) ->
      expect(msg).toBe 'Summary: 0 unsynced stocks, everything is fine'
      done()
    .fail (error) -> done _.prettify error
  , 20000 # 20sec

  # workflow
  # - create a product type
  # - create a product for the master
  # - create a product for the retailer with the mastersku attribute
  # - publish retailer product
  # - create inventory item in retailer
  # - run update
  # - check that master inventory is created
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
      @client.inventoryEntries.save(retailerEntry)
    .then (result) =>
      expect(result.statusCode).toBe 201
      retailerEntryWithNoMatchingProduct =
        sku: uniqueId 'no-matching'
        quantityOnStock: 1
      @client.inventoryEntries.save(retailerEntryWithNoMatchingProduct)
    .then (result) =>
      expect(result.statusCode).toBe 201

      @updater.run()
    .then (msg) =>
      @logger.info msg
      expect(msg).toEqual 'Summary: there were 1 unsynced stocks, (0 were updates and 1 were new) and 1 were successfully synced (0 failed)'

      @client.inventoryEntries.where("sku = \"#{@masterSku}\"").fetch()
    .then (results) ->
      expect(results.statusCode).toBe 200
      expect(results.body.results[0].quantityOnStock).toBe 3
      done()
    .fail (error) -> done _.prettify error
  , 60000 # 1min
