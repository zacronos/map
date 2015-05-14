webpack = require 'webpack'
_ = require 'lodash'
ngAnnotatePlugin = require 'ng-annotate-webpack-plugin'

Config = (output, additionalPlugs, sourceMap = '?sourceMap') ->
  obj =
#    watch:true
    verbose:false
    #http://webpack.github.io/docs/configuration.html#devtool
    devtool: '#eval'#'#eval-source-map' #eval is the fastest it is source map js, where eval-source-map is coffee and jade (ef that)
    resolve:
      modulesDirectories: ['bower_components','node_modules']
    externals:
      "pdfkit": "var PDFDocument"
    plugins: [
        new webpack.ResolverPlugin(
          new webpack.ResolverPlugin.DirectoryDescriptionFilePlugin(
            "bower.json", ["main"])
        )
        new webpack.optimize.DedupePlugin()
        new webpack.optimize.OccurenceOrderPlugin(true)
        new webpack.optimize.AggressiveMergingPlugin()
        new ngAnnotatePlugin()
      ]
    module:
      loaders: [
        { test: /\.css$/, loader: 'style!css!autoprefixer?browsers=last 2 version' }
        { test: /\.styl$/, loader: 'style!css' + sourceMap + '!stylus' } #enables import url for sourceMap, but background-images are broken.. webpack bug?
        { test: /\.scss$/, loader: 'style!css' + sourceMap + '!sass' } #mapbox styles out of the box are scss
#        { test: /\.styl$/, loader: 'style!css!stylus' }
        { test: /\.coffee$/, loader: 'coffee' }
        { test: /\.png$/, loader: 'url?name=./assets/[name].[ext]&limit=10000' }
        { test: /\.jpg$/, loader: 'url?name=./assets/[name].[ext]&limit=10000' }
        { test: /\.woff$/, loader:"url?prefix=font/&limit=5000&mimetype=application/font-woff" }
        { test: /\.ico$/, loader: 'url?name=./assets/[name].[ext]&limit=10000' }
        { test: /\.ttf$/, loader: "file?prefix=font/" }
        { test: /\.eot$/, loader: "file?prefix=font/" }
        { test: /\.jade$/, loader: "html?attrs=img:src!jade-html" }
        { test: /\.html$/, loader: "html?attrs=img:src" }
        {test: /\.json$/, loader: "json"}
      ]
  if output
    # console.info "APPLYING OUTPUT!!! #{_.values(output)}"
    obj.output = output
  if additionalPlugs
    obj.plugins = obj.plugins.concat(additionalPlugs)

  # console.log "Config object: " + _.values obj
  obj


#console.log "Config Class: " + Config
#instance = Config()
#console.log "Config Instance: " + instance
module.exports = Config
