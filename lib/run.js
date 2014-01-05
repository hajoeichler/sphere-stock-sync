/* ===========================================================
# sphere-stock-sync - v0.0.2
# ==============================================================
# Copyright (c) 2013 Hajo Eichler
# Licensed under the MIT license.
*/
var Config, MarketPlaceStockUpdater, argv, updater;

Config = require('../config');

argv = require('optimist').usage('Usage: $0 --projectKey key --clientId id --clientSecret secret').demand(['projectKey', 'clientId', 'clientSecret']).argv;

MarketPlaceStockUpdater = require('../main').MarketPlaceStockUpdater;

updater = new MarketPlaceStockUpdater(Config, argv.projectKey, argv.clientId, argv.clientSecret);

updater.run(function(msg) {
  console.log(msg);
  if (!msg.status) {
    return process.exit(1);
  }
});
