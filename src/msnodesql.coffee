{Pool} = require 'generic-pool'
msnodesql = require 'msnodesql'
util = require 'util'

TYPES = require('./datatypes').TYPES
UDT = require('./udt').PARSERS
ISOLATION_LEVEL = require('./isolationlevel')
DECLARATIONS = require('./datatypes').DECLARATIONS
EMPTY_BUFFER = new Buffer(0)

CONNECTION_STRING_PORT = 'Driver={SQL Server Native Client 11.0};Server={#{server},#{port}};Database={#{database}};Uid={#{user}};Pwd={#{password}};Trusted_Connection={#{trusted}};'
CONNECTION_STRING_NAMED_INSTANCE = 'Driver={SQL Server Native Client 11.0};Server={#{server}\\#{instance}};Database={#{database}};Uid={#{user}};Pwd={#{password}};Trusted_Connection={#{trusted}};'

###
@ignore
###

castParameter = (value, type) ->
	unless value?
		if type is TYPES.Binary or type is TYPES.VarBinary or type is TYPES.Image
			# msnodesql has some problems with NULL values in those types, so we need to replace it with empty buffer
			return EMPTY_BUFFER
		
		return null
	
	switch type
		when TYPES.VarChar, TYPES.NVarChar, TYPES.Char, TYPES.NChar, TYPES.Xml, TYPES.Text, TYPES.NText
			if typeof value isnt 'string' and value not instanceof String
				value = value.toString()
		
		when TYPES.Int, TYPES.TinyInt, TYPES.BigInt, TYPES.SmallInt
			if typeof value isnt 'number' and value not instanceof Number
				value = parseInt(value)
				if isNaN(value) then value = null
				
		when TYPES.Float, TYPES.Real, TYPES.Decimal, TYPES.Numeric, TYPES.SmallMoney, TYPES.Money
			if typeof value isnt 'number' and value not instanceof Number
				value = parseFloat(value)
				if isNaN(value) then value = null
		
		when TYPES.Bit
			if typeof value isnt 'boolean' and value not instanceof Boolean
				value = Boolean(value)
		
		when TYPES.DateTime, TYPES.SmallDateTime, TYPES.DateTimeOffset, TYPES.Date
			if value not instanceof Date
				value = new Date(value)
		
		when TYPES.Binary, TYPES.VarBinary, TYPES.Image
			if value not instanceof Buffer
				value = new Buffer(value.toString())

	value

###
@ignore
###

createColumns = (meta) ->
	out = {}
	for value in meta
		out[value.name] =
			name: value.name
			size: value.size
			type: DECLARATIONS[value.sqlType]
		
		if value.udtType?
			out[value.name].udt =
				name: value.udtType
			
			if DECLARATIONS[value.udtType]
				out[value.name].type = DECLARATIONS[value.udtType]
			
	out

###
@ignore
###

typeDeclaration = (type, length) ->
	switch type
		when TYPES.VarChar, TYPES.NVarChar, TYPES.VarBinary
			return "#{type.name} (MAX)"
		when TYPES.Char, TYPES.NChar, TYPES.Binary
			return "#{type.name} (#{length ? 1})"
		else
			return type.name

###
@ignore
###

isolationLevelDeclaration = (type) ->
	switch type
		when ISOLATION_LEVEL.READ_UNCOMMITTED then return "READ UNCOMMITTED"
		when ISOLATION_LEVEL.READ_COMMITTED then return "READ COMMITTED"
		when ISOLATION_LEVEL.REPEATABLE_READ then return "REPEATABLE READ"
		when ISOLATION_LEVEL.SERIALIZABLE then return "SERIALIZABLE"
		when ISOLATION_LEVEL.SNAPSHOT then return "SNAPSHOT"
		else throw new TransactionError "Invalid isolation level."

###
@ignore
###

valueCorrection = (value, metadata) ->
	if metadata.sqlType is 'time' and value?
		value.setFullYear(1970)
		value
		
	else if metadata.sqlType is 'udt' and value?
		if UDT[metadata.udtType]
			UDT[metadata.udtType] value
			
		else
			value
		
	else
		value

###
@ignore
###

module.exports = (Connection, Transaction, Request, ConnectionError, TransactionError, RequestError) ->
	class MsnodesqlConnection extends Connection
		pool: null
		
		connect: (config, callback) ->
			defaultConnectionString = CONNECTION_STRING_PORT
			
			if config.options.instanceName?
				defaultConnectionString = CONNECTION_STRING_NAMED_INSTANCE
			
			cfg =
				connectionString: config.connectionString ? defaultConnectionString
			
			cfg.connectionString = cfg.connectionString.replace new RegExp('#{([^}]*)}', 'g'), (p) ->
				key = p.substr(2, p.length - 3)
				if key is 'instance'
					return config.options.instanceName
				else if key is 'trusted'
					return if config.options.trustedConnection then 'Yes' else 'No'
				else
					return config[key] ? ''

			cfg_pool =
				name: 'mssql'
				max: 10
				min: 0
				idleTimeoutMillis: 30000
				create: (callback) =>
					msnodesql.open cfg.connectionString, (err, c) =>
						if err then err = ConnectionError err
						if err then return callback err, null # there must be a second argument null
						callback null, c
				
				validate: (c) ->
					c?
				
				destroy: (c) ->
					c?.close()
			
			if config.pool
				for key, value of config.pool
					cfg_pool[key] = value

			@pool = Pool cfg_pool, cfg
			
			#create one testing connection to check if everything is ok
			@pool.acquire (err, connection) =>
				if err and err not instanceof Error then err = new Error err
				
				# and release it immediately
				@pool.release connection
				callback err
			
		close: (callback) ->
			unless @pool then return callback null
			
			@pool.drain =>
				@pool.destroyAllNow()
				@pool = null
				callback null
	
	class MsnodesqlTransaction extends Transaction
		begin: (callback) ->
			@connection.pool.acquire (err, connection) =>
				if err then return callback err
				
				@_pooledConnection = connection
				
				@request().query "set transaction isolation level #{isolationLevelDeclaration(@isolationLevel)};begin tran;", callback
			
		commit: (callback) ->
			@request().query 'commit tran', (err) =>
				@connection.pool.release @_pooledConnection
				@_pooledConnection = null
				callback err

		rollback: (callback) ->
			@request().query 'rollback tran', (err) =>
				@connection.pool.release @_pooledConnection
				@_pooledConnection = null
				callback err

	class MsnodesqlRequest extends Request
		connection: null # ref to connection

		_acquire: (callback) ->
			if @transaction
				@transaction.queue callback
			else
				@connection.pool.acquire callback
		
		_release: (connection) ->
			if @transaction
				@transaction.next()
			else
				@connection.pool.release connection

		query: (command, callback) ->
			if @verbose and not @nested then console.log "---------- sql query ----------\n    query: #{command}"
			
			if command.length is 0
				return process.nextTick ->
					if @verbose and not @nested
						console.log "---------- response -----------"
						elapsed = Date.now() - started
						console.log " duration: #{elapsed}ms"
						console.log "---------- completed ----------"
		
					callback? null, if @multiple or @nested then [] else null
			
			row = null
			columns = null
			recordset = null
			recordsets = []
			started = Date.now()
			handleOutput = false
			
			# nested = function is called by this.execute
			
			unless @nested
				input = ("@#{param.name} #{typeDeclaration(param.type, param.length)}" for name, param of @parameters)
				sets = ("set @#{param.name}=?" for name, param of @parameters when param.io is 1)
				output = ("@#{param.name} as '#{param.name}'" for name, param of @parameters when param.io is 2)
				if input.length then command = "declare #{input.join ','};#{sets.join ';'};#{command};"
				if output.length
					command += "select #{output.join ','};"
					handleOutput = true
			
			@_acquire (err, connection) =>
				unless err
					req = connection.queryRaw command, (castParameter(param.value, param.type) for name, param of @parameters when param.io is 1)
					if @verbose and not @nested then console.log "---------- response -----------"
					
					req.on 'meta', (metadata) =>
						if row
							if @verbose
								console.log util.inspect(row)
								console.log "---------- --------------------"

							unless row["___return___"]?
								# row with ___return___ col is the last row
								@emit 'row', row
						
						if recordset
							@emit 'recordset', recordset
						
						row = null
						columns = metadata
						recordset = []
						Object.defineProperty recordset, 'columns', 
							enumerable: false
							value: createColumns(metadata)
							
						recordsets.push recordset
						
					req.on 'row', (rownumber) =>
						if row
							if @verbose
								console.log util.inspect(row)
								console.log "---------- --------------------"

							unless row["___return___"]?
								# row with ___return___ col is the last row
								@emit 'row', row
						
						row = {}
						recordset.push row
						
					req.on 'column', (idx, data, more) =>
						data = valueCorrection(data, columns[idx])

						exi = row[columns[idx].name]
						if exi?
							if exi instanceof Array
								exi.push data
								
							else
								row[columns[idx].name] = [exi, data]
						
						else
							row[columns[idx].name] = data
			
					req.once 'error', (err) =>
						if @verbose and not @nested
							elapsed = Date.now() - started
							console.log "    error: #{err}"
							console.log " duration: #{elapsed}ms"
							console.log "---------- completed ----------"
							
						callback? RequestError err
					
					req.once 'done', =>
						unless @nested
							# if nested queries, last recordset is full of return values
							if recordset
								@emit 'recordset', recordset
								
							if @verbose
								if row
									console.log util.inspect(row)
									console.log "---------- --------------------"
		
							# do we have output parameters to handle?
							if handleOutput
								last = recordsets.pop()?[0]
		
								for name, param of @parameters when param.io is 2
									param.value = last[param.name]
				
									if @verbose
										console.log "   output: @#{param.name}, #{param.type.name}, #{param.value}"
							
							if @verbose
								elapsed = Date.now() - started
								console.log " duration: #{elapsed}ms"
								console.log "---------- completed ----------"

						@_release connection
						callback? null, if @multiple or @nested then recordsets else recordsets[0]
				
				else
					if connection then @_release connection
					callback? err
	
		execute: (procedure, callback) ->
			if @verbose then console.log "---------- sql execute --------\n     proc: #{procedure}"
	
			started = Date.now()
			
			cmd = "declare #{['@___return___ int'].concat("@#{param.name} #{typeDeclaration(param.type, param.length)}" for name, param of @parameters when param.io is 2).join ', '};"
			cmd += "exec @___return___ = #{procedure} "
			
			spp = []
			for name, param of @parameters
				if param.io is 2
					# output parameter
					spp.push "@#{param.name}=@#{param.name} output"
				else
					if @verbose
						console.log "    input: @#{param.name}, #{param.type.name}, #{param.value}"
							
					# input parameter
					spp.push "@#{param.name}=?"
			
			cmd += "#{spp.join ', '};"
			cmd += "select #{['@___return___ as \'___return___\''].concat("@#{param.name} as '#{param.name}'" for name, param of @parameters when param.io is 2).join ', '};"
			
			if @verbose then console.log "---------- response -----------"
			
			@nested = true
			
			# direct call to query, in case method on main request object is overriden (e.g. co-mssql)
			MsnodesqlRequest::query.call @, cmd, (err, recordsets) =>
				@nested = false
				
				if err
					if @verbose
						elapsed = Date.now() - started
						console.log "    error: #{err}"
						console.log " duration: #{elapsed}ms"
						console.log "---------- completed ----------"
					
					callback? err
				
				else
					last = recordsets.pop()?[0]
					if last and last.___return___?
						returnValue = last.___return___
						
						for name, param of @parameters when param.io is 2
							param.value = last[param.name]
		
							if @verbose
								console.log "   output: @#{param.name}, #{param.type.name}, #{param.value}"
		
					if @verbose
						elapsed = Date.now() - started
						console.log "   return: #{returnValue}"
						console.log " duration: #{elapsed}ms"
						console.log "---------- completed ----------"
					
					recordsets.returnValue = returnValue
					callback? null, recordsets, returnValue
					
		###
		Cancel currently executed request.
		###
		
		cancel: ->
			false # Request canceling is not implemented by msnodesql driver.
	
	return {
		Connection: MsnodesqlConnection
		Transaction: MsnodesqlTransaction
		Request: MsnodesqlRequest
		fix: -> # there is nothing to fix in this driver
	}