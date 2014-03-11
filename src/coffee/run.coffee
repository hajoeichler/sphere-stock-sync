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
    { level: 'error', stream: process.stderr }
    { level: argv.logLevel, path: "#{argv.logDir}/sphere-stock-sync-#{argv.projectKey}.log" }
  ]

process.on 'SIGUSR2', ->
  logger.reopenFileStreams()

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
  exitCode = 0
  if msg.status
    logger.info msg
  else
    logger.error msg
    exitCode = 1
  process.on 'exit', ->
    process.exit exitCode
