_ = require 'lodash'
logger = require('../config/logger').spawn('backend:service:dataSource')
ServiceCrud = require '../utils/crud/util.ezcrud.service.helpers'
tables = require '../config/tables'


class DataSourceService extends ServiceCrud

  getColumnList: (dataSourceId, dataSourceType, dataListType) ->
    @debug "getColumnList(), dataSourceId=#{dataSourceId}, dataSourceType=#{dataSourceType}, dataListType=#{dataListType}"
    query = tables.config.dataSourceFields()
    .select(
      'MetadataEntryID',
      'SystemName',
      'ShortName',
      'LongName',
      'DataType',
      'Interpretation',
      'LookupName'
    )
    .where
      data_source_id: dataSourceId
      data_source_type: dataSourceType
      data_list_type: dataListType
    @custom(query)

  getLookupTypes: (dataSourceId, lookupId) ->
    @debug "getLookupTypes(), dataSourceId=#{dataSourceId}, lookupId=#{lookupId}"
    query = tables.config.dataSourceLookups()
    .select(
      'LookupName',
      'LongValue',
      'ShortValue',
      'Value'
    )
    .where
      LookupName: lookupId
      data_source_id: dataSourceId
    @custom(query)

module.exports = new DataSourceService tables.config.dataSourceFields,
  idKey: "MetadataEntryID"
