Config = require '../config'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
MarketPlaceStockUpdater = require('../main').MarketPlaceStockUpdater

updater = new MarketPlaceStockUpdater(Config, argv.projectKey, argv.clientId, argv.clientSecret)
updater.run (msg) ->
  if msg.status
    console.log msg
    process.exit 0
  console.error msg
  process.exit 1