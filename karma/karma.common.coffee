module.exports = (config, webpackConf) ->
  webpackConf.disableSha1 = true
  webpackConf.disableLogging = true
  # console.info "webpackConf: %j", webpackConf
  webpack: webpackConf
  webpackServer:
    stats:
      colors: true
#webpackPort: 4444
# base path that will be used to resolve all patterns (eg. files, exclude)
  basePath: ''

# frameworks to use
# available frameworks: https://npmjs.org/browse/keyword/karma-adapter
  frameworks: ['mocha','fixture','chai', 'expect']

# preprocess matching files before serving them to the browser
# available preprocessors: https://npmjs.org/browse/keyword/karma-preprocessor
  preprocessors: {
    '../spec/common/**/*spec.coffee': ['webpack']
    '../spec/app/**/*spec.coffee': ['webpack']
    '../spec/fixtures/*.html': ['html2js']
    '../spec/fixtures/*.json': ['html2js']
    '../bower_components/angular-google-maps/spec/coffee/helpers/google-api-mock.coffee': ['coffee']
  #'_public/*.js': ['coverage']
  }

  coverageReporter:
    reporters:[
      { type : 'html', dir : '../_public/coverage/', subdir: "application" }
      { type : 'cobertura', dir : '../_public/coverage/', subdir: "application" }
    ]

# list of files / patterns to load in the browser
  files: [
    '../node_modules/phantomjs-polyfill/bind-polyfill.js'
    '../_public/scripts/vendor.js'
    '../_public/styles/vendor.css'
    '../_public/scripts/main.wp.js'
    '../bower_components/angular-google-maps/spec/coffee/helpers/google-api-mock.coffee'
    '../spec/fixtures/*.html'
    '../spec/fixtures/*.json'
    '../spec/app/bootstrap.spec.coffee'
    '../spec/common/**/*spec.coffee'
    '../spec/app/**/*spec.coffee'
    #do not include those specs for jasmine html runner by karma kama_jasmine_runner.html
    {pattern:'*coffee', included: false}
  ]

# list of files to exclude
  exclude: [
  ]

# test results reporter to use
# possible values: 'dots', 'progress'
# available reporters: https://npmjs.org/browse/keyword/karma-reporter
# NOTE , TODO 'html' reporter use if you want to hit the karma jasmine runner (frequently causes karma to blow up at the end of run),
# test results reporter to use
# possible values: 'dots', 'progress', 'mocha'
  reporters: ['mocha']

# htmlReporter:
#   middlePathDir: "chrome"
#   outputDir: '_public/karma_html',
#   templatePath: 'spec/karma_jasmine_runner.html'

# web server port
  port: 9876

# enable / disable colors in the output (reporters and logs)
  colors: true

# level of logging
# possible values:
# - config.LOG_DISABLE
# - config.LOG_ERROR
# - config.LOG_WARN
# - config.LOG_INFO
# - config.LOG_DEBUG
  logLevel: config.LOG_INFO

# enable / disable watching file and executing tests whenever any file changes
  autoWatch: false

# start these browsers
# available browser launchers: https://npmjs.org/browse/keyword/karma-launcher
  browsers: ['PhantomJS']# options Chrome, PhantomJS
#browserNoActivityTimeout: 200000000000000000000000000000000
# If browser does not capture in given timeout [ms], kill it
  captureTimeout: 60000
# Continuous Integration mode
# if true, Karma captures browsers, runs the tests and exits
  singleRun: false

  plugins: [
    'karma-mocha-reporter'
    'karma-chai'#makes should js work, but it can be loaded directly in a spec
    'karma-expect'
    'karma-coverage'
    'karma-mocha'
    'karma-html2js-preprocessor'
    'karma-fixture'
    #'karma-html-reporter'
    'karma-chrome-launcher'
    'karma-phantomjs-launcher'
    'karma-coffee-preprocessor'
    require('karma-webpack')
  ]

  # urlRoot: "base/dist/karma_html/chrome/index.html"
