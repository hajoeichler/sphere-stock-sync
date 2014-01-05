elasticio = require('../elasticio.js')
Config = require '../config'

describe "elasticio integration", ->
  it "with no attachments nor body", (done) ->
    cfg =
      masterClientId: Config.config.client_id
      masterClientSecret: Config.config.client_secret
      masterProjectKey: Config.config.project_key
      retailerClientId: Config.config.client_id
      retailerClientSecret: Config.config.client_secret
      retailerProjectKey: Config.config.project_key
    msg = ''
    elasticio.process msg, cfg, (next) ->
      expect(next.status).toBe true
      done()