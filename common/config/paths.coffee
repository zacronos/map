appMap = 'frontend/map/'
appAdmin = 'frontend/admin/'
libFront = appMap + 'lib'

dest =
  scripts: 'scripts'
  styles: 'styles'
  fonts: 'fonts'
  assets: 'assets'
  root: '_public/'

tmp =
  scripts: '.tmp/scripts'
  styles: '.tmp/styles'
  fonts: '.tmp/fonts'
  assets: '.tmp/assets'
  serve: '.tmp/serve'

getAssetCollection = (app) ->
  return {
    root: app
    scripts: app + 'scripts/**/*'
    vendorLibs: app + 'lib/scripts/vendor/**/*.*'
    webpackLibs: app + 'lib/scripts/webpack/**/*.*'
    css: app + 'styles/**/*.css'
    stylus: app + 'styles/main.styl'
    less: app + 'styles/**/*.less'
    stylusWatch: app + 'styles/**/*'
    svg: app + 'html/svg/*.svg'
    html: app + 'html/**/*.html'
    jade: app + 'html/**/*.jade'
    json: app + 'json/**/*.json'
    assets: app + 'assets/**/*.*'
  }

module.exports =
  bower: 'bower_components'
  spec: 'spec/**'
  common: 'common/**/*.*'
  webroot: 'common/webroot/**/*.*'

  rmap: getAssetCollection(appMap)
  admin: getAssetCollection(appAdmin)

  lib:
    front:
      scripts: libFront + '/scripts'
      styles: libFront + '/styles'
      fonts: libFront + '/fonts'
    back: 'backend/lib'

  dest: dest
  tmp: tmp
  destFull:
    assets: dest.root + dest.assets
    scripts: dest.root + dest.scripts
    styles: dest.root + dest.styles
    fonts: dest.root + dest.fonts
    index: dest.root + 'rmap.html'
    admin: dest.root + 'admin.html'
    webpack:
      map:
        # publicPath: 'http://0.0.0.0:4000/'#for dev only, https://github.com/webpack/style-loader/issues/55, https://github.com/webpack/css-loader/issues/29
        filename: dest.scripts + "/main.wp.js"
        chunkFilename: dest.scripts + "/main.wp.js"
      admin:
        # publicPath: 'http://0.0.0.0:4000/'#for dev only
        filename: dest.scripts + "/admin.wp.js"
        chunkFilename: dest.scripts + "/adminChunk.wp.js"
