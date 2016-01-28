crudService = require '../utils/crud/util.crud.service.helpers'
tables = require '../config/tables'
dbs = require '../config/dbs'

db = dbs.get('main')

class MailService extends crudService.ThenableCrud
  getAll: (query = {}, doLogQuery = false) ->
    transaction = @dbFn
    tableName = @dbFn.tableName

    @dbFn = () =>
      ret = transaction().select(
        "#{tables.mail.campaign.tableName}.*",
        db.raw("#{tables.user.project.tableName}.name as project_name"),
        db.raw("#{tables.mail.campaign.tableName}.project_id as project_id")
      )
      .join("#{tables.user.project.tableName}", () ->
        this.on("#{tables.mail.campaign.tableName}.project_id", "#{tables.user.project.tableName}.id")
      )
      .where(query)

      @dbFn = transaction
      ret
    @dbFn.tableName = tableName
    super(query, doLogQuery)

instance = new MailService(tables.mail.campaign).init(false,false,false)
module.exports = instance
