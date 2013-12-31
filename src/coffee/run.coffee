Config = require '../config'
argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret')
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv
MarketPlaceStockUpdater = require('../main').MarketPlaceStockUpdater

Config.timeout = 60000
Config.showProgress = true

updater = new MarketPlaceStockUpdater(Config, argv.projectKey, argv.clientId, argv.clientSecret)
updater.run (msg) ->
  console.log msg
  process.exit 1 unless msg.status