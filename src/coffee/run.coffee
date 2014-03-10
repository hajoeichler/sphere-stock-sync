package_json = require '../package.json'
Config = require '../config'
Logger = require './logger'
MarketPlaceStockUpdater = require '../lib/retailer2master'

argv = require('optimist')
  .usage('Usage: $0 --projectKey key --clientId id --clientSecret secret --logDir dir --logLevel level --timeout timeout')
  .default('logLevel', 'info')
  .default('logDir', '.')
  .default('timeout', 60000)
  .demand(['projectKey','clientId', 'clientSecret'])
  .argv

logger = new Logger
  streams: [
    { level: 'warn', stream: process.stderr }
    { level: argv.logLevel, type: 'rotating-file', period: '1d', count: 90, path: "#{argv.logDir}/sphere-stock-sync-#{argv.projectKey}.log" }
  ]

options =
  baseConfig:
    timeout: argv.timeout
    user_agent: "#{package_json.name} - #{package_json.version}"
    logConfig:
      logger: logger
  master: Config.config
  retailer:
    project_key: argv.projectKey
    client_id: argv.clientId
    client_secret: argv.clientSecret

updater = new MarketPlaceStockUpdater options
updater.run (msg) ->
  if msg.status
    logger.info msg
    process.exit 0
  logger.error msg
  process.exit 1