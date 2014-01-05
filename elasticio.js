MarketPlaceStockUpdater = require('./main').MarketPlaceStockUpdater

exports.process = function(msg, cfg, cb, snapshot) {
  options = {
    config: {
      client_id: cfg.masterClientId,
      client_secret: cfg.masterClientSecret,
      project_key: cfg.masterProjectKey
    }
  };
  var updater = new MarketPlaceStockUpdater(options, cfg.retailerProjectKey, cfg.retailerClientId, cfg.retailerClientSecret);
  updater.elasticio(msg, cfg, cb, snapshot);
}