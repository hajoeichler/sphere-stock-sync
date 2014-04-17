_ = require 'underscore'
Q = require 'q'
{ExtendedLogger} = require 'sphere-node-utils'
package_json = require '../package.json'
MarketPlaceStockUpdater = require '../lib/marketplace-stock-updater'

describe 'MarketPlaceStockUpdater', ->

  beforeEach ->
    logger = new ExtendedLogger
      additionalFields:
        project_key: 'xxx'
      logConfig:
        name: "#{package_json.name}-#{package_json.version}"
        streams: [
          { level: 'info', stream: process.stdout }
        ]

    options =
      baseConfig:
        logConfig:
          logger: logger.bunyanLogger
      master:
        project_key: 'x'
        client_id: 'y'
        client_secret: 'z'
      retailer:
        project_key: 'a'
        client_id: 'b'
        client_secret: 'c'

    @updater = new MarketPlaceStockUpdater options

  describe '#_enhanceWithRetailerChannel', ->
    it 'should add the supplyChannel', ->
      entry =
        sku: '123'
      entries = @updater._enhanceWithRetailerChannel [entry], 'c-1'
      expect(_.size entries).toBe 1
      expect(entries[0].supplyChannel).toBeDefined()
      expect(entries[0].supplyChannel.typeId).toBe 'channel'
      expect(entries[0].supplyChannel.id).toBe 'c-1'

  describe '#_getInventoryWithMapping', ->
    it 'should return true when all master skus are available', ->
      entry =
        sku: 'retailerFoo'
        quantity: 0
      entries = @updater._getInventoryWithMapping [entry], retailerFoo: 'masterBar'
      expect(_.size entries).toBe 1

    it 'should return false if a master sku is missing', ->
      entry =
        sku: 'retailerSKU'
        quantity: 0
      entries = @updater._getInventoryWithMapping [entry], foo: 'bar'
      expect(_.size entries).toBe 0

  describe '#_replaceSKUs', ->
    it 'should use master sku', ->
      entry =
        sku: 'retailerFoo'
        quantity: 0
      entries = @updater._replaceSKUs [entry], retailerFoo: 'masterBar'
      expect(_.size entries).toBe 1
      expect(entries[0].sku).toBe 'masterBar'

  describe '#_createSkuMap', ->
    it 'should create map for masterVariant and all other variants', ->
      product =
        masterVariant:
          sku: 'r123'
          attributes: [
            { name: 'mastersku', value: 'm321' }
          ]
        variants: [
          {
            sku: 'r234'
            attributes: [
              { name: 'mastersku', value: 'm432' }
            ]
          }
        ]
      map = @updater._createSkuMap [product]
      expect(_.size map).toBe 2
      expect(map['r123']).toBe 'm321'
      expect(map['r234']).toBe 'm432'

  describe '#_matchVariant', ->
    it 'should create map entry for master2retailer mapping', ->
      variant =
        sku: 'rSKU'
        attributes: [
          { name: 'mastersku', value: 'mSKU' }
        ]
      r2m = @updater._matchVariant variant
      expect(r2m['rSKU']).toBe 'mSKU'
