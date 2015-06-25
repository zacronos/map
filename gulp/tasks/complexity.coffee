gulp = require 'gulp'
complexity = require 'gulp-complexity'
plumber = require 'gulp-plumber'
paths = require '../../common/config/paths'
log = require('gulp-util').log

gulp.task 'complexityBackend', ->
  gulp.src ['backend/**/*.coffee', 'common/**/*.coffee']
  .pipe complexity
    breakOnErrors:false

gulp.task 'complexityFrontend', ->
  gulp.src ['frontend/**/*.coffee']
  .pipe complexity
    breakOnErrors:false

gulp.task 'complexity', gulp.series 'complexityBackend', 'complexityFrontend'
