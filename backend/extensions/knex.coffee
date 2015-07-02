require './stream'

libs = [
  require 'knex/lib/raw'
  require 'knex/lib/query/builder'
  require 'knex/lib/schema/builder'
]

for key, lib of libs
  lib::stringify = () ->
    @stream().stringify()
