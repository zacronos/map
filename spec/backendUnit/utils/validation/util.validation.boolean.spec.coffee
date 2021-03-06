{basePath} = require '../../globalSetup'
colorWrap = require 'color-wrap'
require('chai').should()
colorWrap(console)

{validators} = require "#{basePath}/utils/util.validation"
{expectResolve} = require('../../../specUtils/promiseUtils')

subject = validators.boolean

describe 'utils/validation.validators.boolean()'.ns().ns('Backend'), ->
  param = 'fake'

  describe 'normal', ->
    [true, false].forEach (bool) ->
      it "#{bool.toString()} is #{bool.toString()}", () ->
        testObj = isTrue: bool.toString()
        expectResolve(subject()(param, testObj.isTrue)).then (value) ->
          value.should.be.equal bool

  describe 'numbers', ->
    [1, 0].forEach (bool) ->
      it "#{bool.toString()} is #{bool.toString()}", () ->
        expectResolve(subject({truthy:1, falsy: 0})(param, bool)).then (value) ->
          value.should.be.equal(!!bool)

    describe 'as string', ->
      ['1', '0'].forEach (bool) ->
        it "#{bool.toString()} is #{bool.toString()}", () ->
          expectResolve(subject({truthy:'1', falsy: '0'})(param, bool)).then (value) ->
            value.should.be.equal(!!parseInt(bool))

  describe 'altered output', ->
    it "should output `yes` & `no` as configured, instead of true & false", () ->
      [true, false].forEach (bool) ->
        expectedOutput = if bool then 'yes' else 'no'
        options =
          truthyOutput: 'yes'
          falsyOutput: 'no'
        expectResolve(subject(options)(param, bool))
        .then (value) ->
          value.should.be.equal expectedOutput

  describe 'inverted', ->

    describe 'just inverted w falsy and truthy', ->
      [true, false].forEach (bool) ->
        it "#{bool.toString()} is #{(!bool).toString()}", () ->
          testObj = isTrue: bool.toString()
          expectResolve(subject(invert:true, truthy: "true", falsy: "false")(param, testObj.isTrue)).then (value) ->
            value.should.be.equal !bool

    describe 'just inverted string', ->
      #NOTE: THE behavior of 'just inverted w falsy and truthy' would make more sense for this and lesss thinking
      [true, false].forEach (bool) ->
        it "#{bool.toString()} is #{(if !bool then bool else !bool).toString()}", () ->
          testObj = isTrue: bool.toString()
          expectResolve(subject(invert:true)(param, testObj.isTrue)).then (value) ->
            if !bool
              # console.log.cyan "#{bool.toString()} is value: #{value.toString()}"
              return value.should.be.equal bool
            value.should.be.equal !bool

    describe 'just inverted boolean', ->
      [true, false].forEach (bool) ->
        it "#{bool.toString()} is #{(!bool).toString()}", () ->
          testObj = isTrue: bool
          expectResolve(subject(invert:true)(param, testObj.isTrue)).then (value) ->
            value.should.be.equal !bool
