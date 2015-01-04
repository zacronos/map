app = require '../app.coffee'

app.constant 'MainOptions'.ourNs(), do () ->
  isDev = (window.location.hostname == 'localhost' || window.location.hostname == '127.0.0.1')
  return {
    map:
      zoomThresholdMilliSeconds: 800
      options:
        logLevel: if isDev then 'debug' else 'error'
        disableDoubleClickZoom:false #does not work well with dblclick properties
        uiGmapLogLevel: 'error'
        streetViewControl: false
        zoomControl: true
        panControl: false
        maxZoom: 20
        minZoom: 3
        throttle:
          eventPeriods:
            mousewheel: 50 # ms - don't let pass more than one event every 50ms.
            mousemove: 200 # ms - don't let pass more than one event every 200ms.
          space: 2
        parcelsZoomThresh: 16
        clusteringThresh: 16
        json:
          zoom: 15
          center:
            latitude: 26.148111
            longitude: -81.790809
    # do logging for local dev only
    doLog: if isDev then true else false
    # logoutDelayMillis is how long to pause on the logout view before redirecting
    logoutDelayMillis: 1500
    # filterDrawDelay is how long to wait when filters are modified to see if more modifications are incoming before querying
    filterDrawDelay: 1000
    isDev: isDev

    alert:
      # ttlMillis is the default for how long to display an alert before automatically hiding it
      ttlMillis: 2*60*1000   # 2 minutes
      # quietMillis is the default for how long is needed before we start to show a previously-closed alert if it happens again
      quietMillis: 30*1000   # 30 seconds
  }
