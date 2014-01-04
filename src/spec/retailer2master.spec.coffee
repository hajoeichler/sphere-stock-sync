MarketPlaceStockUpdater = require('../main').MarketPlaceStockUpdater
Q = require('q')

describe '#matchVariant', ->
  beforeEach ->
    opts =
      config:
        project_key: 'x'
        client_id: 'y'
        client_secret: 'z'
    @updater = new MarketPlaceStockUpdater opts, 'a', 'b', 'c'

  it 'should create hash entry for master2retailer mapping', ->
    variant =
      sku: 'rSKU'
      attributes: [
        { name: 'mastersku', value: 'mSKU' }
      ]
    m2r = @updater.matchVariant variant
    expect(m2r['mSKU']).toBe 'rSKU'
