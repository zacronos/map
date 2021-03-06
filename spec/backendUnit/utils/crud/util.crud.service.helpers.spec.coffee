rewire = require 'rewire'
crudServiceHelpers = rewire '../../../../backend/utils/crud/util.crud.service.helpers'
{Crud, HasManyCrud, ThenableCrud} = crudServiceHelpers
tables = require '../../../../backend/config/tables'
userServices = require '../../../../backend/services/services.user'
Promise = require 'bluebird'
require("chai").should()
{expect} = require("chai")
sinon = require 'sinon'
errorHandlingUtils = require '../../../../backend/utils/errors/util.error.partiallyHandledError'


crudServiceHelpers.__set__('IsIdObjError', class FakeIsIdObjError extends errorHandlingUtils.QuietlyHandledError)


describe 'util.crud.service.helpers', ->
  describe 'Crud', ->
    it 'exists', ->
      Crud.should.be.ok

    describe 'defaults', ->
      before ->
        @instance = new Crud(tables.auth.user)
      it 'ctor', ->
        @instance.dbFn.should.be.equal tables.auth.user
        @instance.idKey.should.be.equal 'id'
      it 'getAll', ->
        @instance.getAll().toString().should.equal 'select * from "auth_user"'

      describe 'clone', ->
        it 'exists', ->
          expect(@instance.clone).to.be.ok

        describe 'works', ->
          beforeEach ->
            @clone = @instance.clone()
          it 'dbFn', ->
            @clone.dbFn.should.be.eql @instance.dbFn
          it 'idKey', ->
            @clone.idKey.should.be.eql @instance.idKey

      describe 'getById', ->
        it 'Number', ->
          @instance.getById(1).toString()
          .should.equal """select * from "#{tables.auth.user.tableName}" where "id" = 1"""

        it 'String', ->
          @instance.getById('1').toString()
          .should.equal """select * from "#{tables.auth.user.tableName}" where "id" = '1'"""

        it 'Object', ->
          @instance.getById(crapId:1,prop2:'prop2').toString()
          .should.equal """select * from "#{tables.auth.user.tableName}" where "crapId" = 1 and "prop2" = 'prop2'"""

        it 'anything else throws', ->
          (=> @instance.getById([]).toString()).should.throw("val:  typeof object must be an object, or Number but not an Array!")

      it 'count', ->
        @instance.count(test:'test').toString()
        .should.equal """select count(*) from "#{tables.auth.user.tableName}" where "test" = 'test'"""

      describe 'update', ->
        it 'no safe', ->
          @instance.update(1, {test:'test'}).toString()
          .should.equal """update "#{tables.auth.user.tableName}" set "test" = 'test' where "id" = 1 returning "id" """.trim()

        it 'safe', ->
          @instance.update(1, {test:'test', crap: 2}, ['test']).toString()
          .should.equal """update "#{tables.auth.user.tableName}" set "test" = 'test' where "id" = 1 returning "id" """.trim()

      describe 'create', ->
        it 'default', ->
          @instance.create({id:1, test:'test'}).toString()
          .should.equal """insert into "#{tables.auth.user.tableName}" ("id", "test") values (1, 'test') returning "id" """.trim()
        it 'id', ->
          @instance.create({id:1, test:'test'}, 2).toString()
          .should.equal """insert into "#{tables.auth.user.tableName}" ("id", "test") values (2, 'test') returning "id" """.trim()

      describe 'upsert', ->
        describe 'record exists', ->
          before ->
            sinon.stub(@instance, 'getAll').returns Promise.try () -> [1]
            sinon.stub(Crud::, 'update').returns Promise.try () -> [1]
            sinon.stub(Crud::, 'create').returns Promise.try () -> [1]

          after ->
            @instance.getAll.restore()
            Crud::update.restore()
            Crud::create.restore()

          it 'with update', ->
            obj = id: 1
            @instance.upsert obj, ['id']
            .then () ->
              Crud::update.called.should.be.true
              Crud::update.reset()

          it 'no update', ->
            obj = id: 1
            @instance.upsert obj, ['id'], false
            .then () ->
              Crud::update.called.should.be.false
              Crud::update.reset()

        describe 'record does not exist', ->
          before ->
            sinon.stub(@instance, 'getAll').returns Promise.try () -> []
            sinon.stub(Crud::, 'update').returns Promise.try () -> [1]
            sinon.stub(Crud::, 'create').returns Promise.try () -> [1]

          after ->
            @instance.getAll.restore()
            Crud::update.restore()
            Crud::create.restore()

          it 'new record', ->
            @instance.upsert id: 1, ['id']
            .then () ->
              Crud::create.called.should.be.true
              Crud::create.reset()

      it 'delete', ->
        @instance.delete(1).toString()
        .should.equal """delete from "#{tables.auth.user.tableName}" where "id" = 1"""

    describe 'overrides', ->
      before ->
        @instance = new Crud(tables.auth.user, 'project_id')

      it 'ctor', ->
        @instance.dbFn.should.be.equal tables.auth.user
        @instance.idKey.should.be.equal 'project_id'

      it 'getAll', ->
        @instance.getAll().toString().should.equal "select * from \"#{tables.auth.user.tableName}\""

      it 'getById', ->
        @instance.getById(1).toString()
        .should.equal """select * from "#{tables.auth.user.tableName}" where "id" = 1""".replace(/id/g, @instance.idKey)

      describe 'update', ->
        it 'no safe', ->
          @instance.update(1, {test:'test'}).toString()
          .should.equal """update "#{tables.auth.user.tableName}" set "test" = 'test' where "id" = 1 returning "id" """.trim().replace(/id/g, @instance.idKey)

        it 'safe', ->
          @instance.update(1, {test:'test', crap: 2}, ['test']).toString()
          .should.equal """update "#{tables.auth.user.tableName}" set "test" = 'test' where "id" = 1 returning "id" """.trim().replace(/id/g, @instance.idKey)

      describe 'create', ->
        it 'default', ->
          @instance.create({project_id:1, test:'test'}).toString()
          .should.equal """insert into "#{tables.auth.user.tableName}" ("id", "test") values (1, 'test') returning "id" """.trim().replace(/id/g, @instance.idKey)
        it 'id', ->
          @instance.create({test:'test'}, 2).toString()
          .should.equal """insert into "#{tables.auth.user.tableName}" ("id", "test") values (2, 'test') returning "id" """.trim().replace(/id/g, @instance.idKey)

      it 'delete', ->
        @instance.delete(1).toString()
        .should.equal """delete from "#{tables.auth.user.tableName}" where "id" = 1""".replace(/id/g, @instance.idKey)


    describe 'ThenableCrud', ->
      it 'exists', ->
        ThenableCrud.should.be.ok

      describe 'defaults', ->
        before ->
          @instance = new ThenableCrud(tables.auth.user)
        it 'ctor', ->
          @instance.dbFn.should.be.equal tables.auth.user
          @instance.idKey.should.be.equal 'id'

        describe 'clone', ->
          it 'exists', ->
            expect(@instance.clone).to.be.ok

          describe 'works', ->
            beforeEach ->
              @clone = @instance.clone()
            it 'dbFn', ->
              @clone.dbFn.should.be.eql @instance.dbFn
            it 'idKey', ->
              @clone.idKey.should.be.eql @instance.idKey
            it 'init', ->
              expect(@clone.init).to.be.ok
