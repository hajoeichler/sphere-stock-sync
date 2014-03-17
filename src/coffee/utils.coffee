Q = require 'q'

# TODO: move it to `sphere-node-client` or `sphere-node-utils`
module.exports =

  pagedFetch: (rest, endpoint)->
    deferred = Q.defer()
    _page = (offset = 0, limit = 100, total, acc = []) ->
      if total? and (offset + limit) >= total + limit
        deferred.notify
          inProgress: false
          message: ' done'
        deferred.resolve acc
      else
        rest.GET endpoint, (error, response, body) ->
          unless total
            deferred.notify
              inProgress: true
              message: "#{body.total} (#{limit} per .): "
          deferred.notify
            inProgress: true
            message: '.'
          if error
            deferred.reject error
          else
            if response.statusCode is 200
              _page(offset + limit, limit, body.total, acc.concat(body.results))
            else
              humanReadable = JSON.stringify body, null, 2
              deferred.reject humanReadable
    _page()
    deferred.promise