gulp = require 'gulp'
mocha = require 'gulp-mocha'
plumber = require 'gulp-plumber'
istanbul = require 'gulp-coffee-istanbul'
paths = require '../../common/config/paths'
logFile = require '../util/logFile'
es = require 'event-stream'
logger = require '../util/logger'

require 'chai'
require('chai').should()

runMocha = (files, reporter = 'dot', done) ->
  gulp.src files, read: false
  # .pipe logFile(es)
  .pipe plumber()
  .pipe mocha
    reporter: reporter
    showStack: true
  .once 'error', (err) ->
    logger.error(err.stack ? err)
    done()
    return process.exit(1)

gulp.task 'backendSpec', (done) ->
  runMocha ['spec/backend/**/*spec*'], undefined, done

gulp.task 'backendDebugSpec', (done) ->
  runMocha ['spec/backend/**/*spec*'], 'spec', done

gulp.task 'commonSpec', (done) ->
  runMocha 'spec/common/**/*spec*', undefined, done

gulp.task 'gulpSpec', (done) ->
  runMocha  'spec/gulp/**/*spec*', undefined, done

gulp.task 'gulpDebugSpec', (done) ->
  runMocha "spec/gulp/**/*spec*", 'spec', done

gulp.task 'mocha', gulp.series 'backendSpec'

gulp.task 'coverFiles', ->
  gulp.src [paths.common, paths.backend].map (f) -> f + '*.coffee'
  # .pipe logFile(es)
  .pipe istanbul()
  .pipe istanbul.hookRequire()

gulp.task 'backendCoverage', gulp.series 'coverFiles', (done) ->
  runMocha ['spec/backend/**/*spec*', 'spec/common/**/*spec*'], undefined, done
  .pipe istanbul.writeReports
    dir: './_public/coverage/application/backend'
    reporters: [ 'html', 'cobertura', 'json', 'text', 'text-summary' ]
  # .pipe(istanbul.enforceThresholds(thresholds: global: 50)) #only working on gulp-istanbul
