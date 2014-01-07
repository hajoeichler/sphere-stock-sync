/* ===========================================================
# sphere-stock-sync - v0.0.4
# ==============================================================
# Copyright (c) 2013 Hajo Eichler
# Licensed under the MIT license.
*/
var InventoryUpdater, MarketPlaceStockUpdater, Q, Rest, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require('underscore')._;

InventoryUpdater = require('sphere-node-sync').InventoryUpdater;

Rest = require('sphere-node-connect').Rest;

Q = require('q');

MarketPlaceStockUpdater = (function(_super) {
  __extends(MarketPlaceStockUpdater, _super);

  function MarketPlaceStockUpdater(options, retailerProjectKey, retailerClientId, retailerClientSecret) {
    var cfg;
    MarketPlaceStockUpdater.__super__.constructor.call(this, options);
    cfg = {
      project_key: retailerProjectKey,
      client_id: retailerClientId,
      client_secret: retailerClientSecret
    };
    this.retailerRest = new Rest({
      config: cfg
    });
  }

  MarketPlaceStockUpdater.prototype.elasticio = function(msg, cfg, cb, snapshot) {
    return this.run(cb);
  };

  MarketPlaceStockUpdater.prototype.run = function(callback) {
    var _this = this;
    return this.allInventoryEntries(this.retailerRest).then(function(retailerStock) {
      return _this.initMatcher().then(function(sku2index) {
        _this.sku2index = sku2index;
        return _this.createOrUpdate(retailerStock, callback);
      }).fail(function(msg) {
        return this.returnResult(false, msg, callback);
      });
    }).fail(function(msg) {
      return this.returnResult(false, msg, callback);
    });
  };

  MarketPlaceStockUpdater.prototype.initMatcher = function() {
    var deferred,
      _this = this;
    deferred = Q.defer();
    Q.all([this.retailerProducts(), this.allInventoryEntries(this.rest)]).then(function(_arg) {
      var es, i, master2retailer, masterStocks, p, rSku, retailerProducts, sku2index, v, _i, _j, _k, _len, _len1, _len2, _ref;
      retailerProducts = _arg[0], masterStocks = _arg[1];
      _this.existingInventoryEntries = masterStocks;
      master2retailer = {};
      for (_i = 0, _len = retailerProducts.length; _i < _len; _i++) {
        p = retailerProducts[_i];
        _.extend(master2retailer, _this.matchVariant(p.masterData.current.masterVariant));
        _ref = p.masterData.current.variants;
        for (_j = 0, _len1 = _ref.length; _j < _len1; _j++) {
          v = _ref[_j];
          _.extend(master2retailer, _this.matchVariant(v));
        }
      }
      sku2index = {};
      for (i = _k = 0, _len2 = masterStocks.length; _k < _len2; i = ++_k) {
        es = masterStocks[i];
        rSku = master2retailer[es.sku];
        if (!rSku) {
          continue;
        }
        sku2index[rSku] = i;
      }
      return deferred.resolve(sku2index);
    }).fail(function(msg) {
      return deferred.reject(msg);
    });
    return deferred.promise;
  };

  MarketPlaceStockUpdater.prototype.retailerProducts = function() {
    var deferred;
    deferred = Q.defer();
    this.retailerRest.GET("/products?limit=0", function(error, response, body) {
      var retailerProducts;
      if (error) {
        return deferred.reject('Error on getting retailers products: ' + error);
      } else if (response.statusCode !== 200) {
        return deferred.reject('Problem on getting retailers products: ' + error);
      } else {
        retailerProducts = JSON.parse(body).results;
        return deferred.resolve(retailerProducts);
      }
    });
    return deferred.promise;
  };

  MarketPlaceStockUpdater.prototype.matchVariant = function(variant) {
    var a, m2r, mSku, rSku, _i, _len, _ref;
    m2r = {};
    rSku = variant.sku;
    if (!rSku) {
      return m2r;
    }
    _ref = variant.attributes;
    for (_i = 0, _len = _ref.length; _i < _len; _i++) {
      a = _ref[_i];
      if (a.name !== 'mastersku') {
        continue;
      }
      mSku = a.value;
      if (!mSku) {
        return m2r;
      }
      m2r[mSku] = rSku;
      break;
    }
    return m2r;
  };

  MarketPlaceStockUpdater.prototype.create = function(stock) {
    var deferred;
    deferred = Q.defer();
    this.tickProgress();
    deferred.resolve('The updater will not create new inventory entry. sku: ' + stock.sku);
    return deferred.promise;
  };

  return MarketPlaceStockUpdater;

})(InventoryUpdater);

module.exports = MarketPlaceStockUpdater;
