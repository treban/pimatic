###
Framework
=========
###

assert = require 'cassert'
fs = require "fs"
JaySchema = require 'jayschema'
RJSON = require 'relaxed-json'
i18n = require 'i18n'
express = require "express"
socketIo = require 'socket.io'
# Require engine.io from socket.io
engineIo = require.cache[require.resolve('socket.io')].require('engine.io')
Promise = require 'bluebird'
path = require 'path'
S = require 'string'
_ = require 'lodash'
declapi = require 'decl-api'
util = require 'util'
cjson = require 'cjson'

module.exports = (env) ->

  class Framework extends require('events').EventEmitter
    configFile: null
    app: null
    io: null
    ruleManager: null
    pluginManager: null
    variableManager: null
    deviceManager: null
    groupManager: null
    pageManager: null
    database: null
    config: null
    _publicPathes: {}

    constructor: (@configFile) ->
      assert configFile?
      @maindir = path.resolve __dirname, '..'
      env.logger.winston.on("logged", (level, msg, meta) => 
        @_emitMessageLoggedEvent(level, msg, meta)
      )
      @pluginManager = new env.plugins.PluginManager(this)
      @pluginManager.on('updateProcessStatus', (status, info) =>
        @_emitUpdateProcessStatus(status, info)
      )
      @pluginManager.on('updateProcessMessage', (message, info) =>
        @_emitUpdateProcessMessage(message, info)
      )
      @packageJson = @pluginManager.getInstalledPackageInfo('pimatic')
      env.logger.info "Starting pimatic version #{@packageJson.version}"
      @_loadConfig()
      @pluginManager.pluginsConfig = @config.plugins
      @userManager = new env.users.UserManager(this, @config.users, @config.roles)
      @deviceManager = new env.devices.DeviceManager(this, @config.devices)
      @groupManager = new env.groups.GroupManager(this, @config.groups)
      @pageManager = new env.pages.PageManager(this, @config.pages)
      @variableManager = new env.variables.VariableManager(this, @config.variables)
      @ruleManager = new env.rules.RuleManager(this, @config.rules)
      @database = new env.database.Database(this, @config.settings.database)
      
      @deviceManager.on('deviceRemoved', (device) =>
        group = @groupManager.getGroupOfDevice(device.id)
        @groupManager.removeDeviceFromGroup(group.id, device.id) if group?
      )
      @ruleManager.on('ruleRemoved', (rule) =>
        group = @groupManager.getGroupOfRule(rule.id)
        @groupManager.removeRuleFromGroup(group.id, rule.id) if group?
      )
      @variableManager.on('variableRemoved', (variable) =>
        group = @groupManager.getGroupOfVariable(variable.name)
        @groupManager.removeVariableFromGroup(group.id, variable.name) if group?
      )

      @_setupExpressApp()



    _validateConfig: (config, schema, scope = "config") ->
      js = new JaySchema()
      errors = js.validate(config, schema)
      if errors.length > 0
        errorMessage = "Invalid #{scope}: "
        for e in errors
          if e.desc?
            errorMessage += e.desc
          else
            errorMessage += (
              "\n#{e.instanceContext}: Should have #{e.constraintName} #{e.constraintValue}"
            )
            if e.testedValue? then errorMessage += ", was: #{e.testedValue}"
        throw new Error(errorMessage)

    _loadConfig: () ->
      schema = require("../config-schema")
      contents = fs.readFileSync(@configFile).toString()
      instance = cjson.parse(RJSON.transform(contents))

      # some legacy support for old single user
      auth = instance.settings?.authentication
      if auth?.username? and auth?.password? and (not instance.users?)
        unless instance.users?
          instance.users = [
            {
              username: auth.username,
              password: auth.password,
              role: "admin"
            }
          ]
          delete auth.username
          delete auth.password
          env.logger.warn("Move user authentication setting to new users definition!")

      @_validateConfig(instance, schema)
      @config = declapi.enhanceJsonSchemaWithDefaults(schema, instance)
      for role, i in @config.roles
        @config.roles[i] = declapi.enhanceJsonSchemaWithDefaults(
          schema.properties.roles.items,
          role
        )
      assert Array.isArray @config.plugins
      assert Array.isArray @config.devices
      assert Array.isArray @config.pages
      assert Array.isArray @config.groups
      @_checkConfig()

      # * Set the log level
      env.logger.winston.transports.taggedConsoleLogger.level = @config.settings.logLevel

      i18n.configure({
        locales:['en', 'de'],
        directory: __dirname + '/../locales',
        defaultLocale: @config.settings.locale,
      })

    _checkConfig: ()->

      logWarning = (type, id, name, collection = "group") ->
        env.logger.warn(
          """Could not find a #{type} with the id "#{id}" from """ + 
          """#{collection} "#{name}" in #{type}s config section."""
        )        

      for group in @config.groups
        for deviceId in group.devices
          found = _.find(@config.devices, {id: deviceId})
          unless found?
            logWarning('device', deviceId, group.id)
        for ruleId in group.rules
          found = _.find(@config.rules, {id: ruleId})
          unless found?
            logWarning('rule', ruleId, group.id)
        for variableName in group.variables
          found = _.find(@config.variables, {name: variableName})
          unless found?
            logWarning('variable', variableName, group.id)

      for page in @config.pages
        for item in page.devices
          found = _.find(@config.devices, {id: item.deviceId})
          unless found?
            logWarning('device', item.deviceId, page.id, 'page')

    _setupExpressApp: () ->
      # Setup express
      # -------------
      @app = express()
      #@app.use express.logger()
      @app.use express.cookieParser()
      @app.use express.urlencoded(limit: '10mb')
      @app.use express.json(limit: '10mb')
      auth = @config.settings.authentication
      validSecret = (
        auth.secret? and typeof auth.secret is "string" and auth.secret.length >= 32
      )
      unless validSecret
        auth.secret = require('crypto').randomBytes(64).toString('base64')

      assert typeof auth.secret is "string"
      assert auth.secret.length >= 32

      @app.cookieSessionOptions = {
        secret:  auth.secret
        key: 'pimatic.sess'
        cookie: { maxAge: null }        
      }
      @app.use express.cookieSession(@app.cookieSessionOptions)
      # Setup authentication
      # ----------------------
      # Use http-basicAuth if authentication is not disabled.
      
      assert auth.enabled in [yes, no]

      if auth.enabled is yes
        for user in @config.users
          #Check authentication.
          validUsername = (
            user.username? and typeof user.username is "string" and user.username.length isnt 0
          )
          unless validUsername
            throw new Error(
              "Authentication is enabled, but no username is defined for a user. " +
              "Please define a username in the user section of the config.json file."
            )
          validPassword = (
            user.password? and typeof user.password is "string" and user.password.length isnt 0
          )
          unless validPassword
            throw new Error(
              "Authentication is enabled, but no password is defined for the user " +
              "\"#{user.username}\". Please define a password for \"#{user.username}\" " +
              "in the users section of the config.json file or disable authentication."
            )

      #req.path
      @app.use( (req, res, next) =>
        if req.path is "/login" then return next()

        # auth is deactivated so we allways continue
        if auth.enabled is no
          req.session.username = ''
          return next()

        if @userManager.isPublicAccessAllowed(req)
          return next()

        # if already logged in so just continue
        loggedIn = (
          typeof req.session.username is "string" and 
          typeof req.session.loginToken is "string" and 
          req.session.username.length > 0 and
          req.session.loginToken.length > 0 and
          @userManager.checkLoginToken(auth.secret, req.session.username, req.session.loginToken)
        )
        if loggedIn
          return next()
 
        # else use authorization
        express.basicAuth( (user, pass) =>
          if @userManager.checkLogin(user, pass)
            role = @userManager.getUserByUsername(user).role
            assert role? and typeof role is "string" and role.length > 0
            req.session.username = user
            req.session.loginToken = @userManager.getLoginTokenForUsername(auth.secret, user)
            req.session.role = role
          else
            delete req.session.username
            delete req.session.loginToken
            delete req.session.role
          # return allwys true, so that the next callback below is called and we can awnser with
          # 401 instead of show the auth dialog
          return yes
        )(req, res, next)
      )

        
      @app.post('/login', (req, res) =>
        user = req.body.username
        password = req.body.password
        rememberMe = req.body.rememberMe
        if rememberMe is 'true' then rememberMe = yes
        if rememberMe is 'false' then rememberMe = no
        rememberMe = !!rememberMe

        if @userManager.checkLogin(user, password)
          role = @userManager.getUserByUsername(user).role
          assert role? and typeof role is "string" and role.length > 0
          req.session.username = user
          req.session.loginToken = @userManager.getLoginTokenForUsername(auth.secret, user)
          req.session.role = role
          req.session.rememberMe = rememberMe
          if rememberMe and auth.loginTime isnt 0
            req.session.cookie.maxAge = auth.loginTime
          else
            req.session.cookie.maxAge = null
          res.send({
            success: yes
            username: user
            role: role
            rememberMe: rememberMe
          })
        else
          delete req.session.username
          delete req.session.loginToken
          delete req.session.role
          delete req.session.rememberMe
          res.send(401, {
            success: false
            message: __("Wrong username or password.")
          })
      )

      @app.get('/logout', (req, res) =>
        delete req.session.username
        delete req.session.loginToken
        delete req.session.role
        res.send 401, "Yor are now logged out."
        return
      )
      serverEnabled = (
        @config.settings.httpsServer?.enabled or @config.settings.httpServer?.enabled
      )

      unless serverEnabled 
        env.logger.warn "You have no https and no http server enabled!"

      @_initRestApi()

      socketIoPath = '/socket.io'
      engine = new engineIo.Server({path: socketIoPath})
      @io = new socketIo()
      ioCookieParser = express.cookieParser(@app.cookieSessionOptions.secret)
      @io.use( (socket, next) =>
        if auth.enabled is no
          return next()
        req = socket.request 
        if req.headers.cookie?
          req.cookies = null
          ioCookieParser(req, null, =>
            sessionCookie = req.signedCookies?[@app.cookieSessionOptions.key]
            loggedIn = (
              sessionCookie? and (
                typeof sessionCookie.username is "string" and 
                typeof sessionCookie.loginToken is "string" and 
                sessionCookie.username.length > 0 and
                sessionCookie.loginToken.length > 0 and
                @userManager.checkLoginToken(
                  auth.secret, 
                  sessionCookie.username, 
                  sessionCookie.loginToken
                )
              )
            )
            if loggedIn
              socket.username = sessionCookie.username
              return next()
            else 
              env.logger.debug "socket.io: Cookie is invalid."
              return next(new Error('Authentication error'))
          )
        else
          env.logger.warn "No cookie transmitted."
          return next(new Error('unauthorizied'))
      )

      @io.bind(engine)

      @app.all( '/socket.io/socket.io.js', (req, res) => @io.serve(req, res) )
      @app.all( '/socket.io/*', (req, res) => engine.handleRequest(req, res) )

      onUpgrade = (req, socket, head) =>
        if socketIoPath is req.url.substr(0, socketIoPath.length)
          engine.handleUpgrade(req, socket, head)
        else
          socket.end()
        return

      # Start the https-server if it is enabled.
      if @config.settings.httpsServer?.enabled
        httpsConfig = @config.settings.httpsServer
        assert httpsConfig instanceof Object
        assert typeof httpsConfig.keyFile is 'string' and httpsConfig.keyFile.length isnt 0
        assert typeof httpsConfig.certFile is 'string' and httpsConfig.certFile.length isnt 0 

        httpsOptions = {}
        httpsOptions[name] = value for name, value of httpsConfig
        httpsOptions.key = fs.readFileSync path.resolve(@maindir, '../..', httpsConfig.keyFile)
        httpsOptions.cert = fs.readFileSync path.resolve(@maindir, '../..', httpsConfig.certFile)
        https = require "https"
        @app.httpsServer = https.createServer httpsOptions, @app
        @app.httpsServer.on('upgrade', onUpgrade)

      # Start the http-server if it is enabled.
      if @config.settings.httpServer?.enabled
        http = require "http"
        @app.httpServer = http.createServer @app
        @app.httpServer.on('upgrade', onUpgrade)

      actionsWithBindings = [
        [env.api.framework.actions, this]
        [env.api.rules.actions, @ruleManager]
        [env.api.variables.actions, @variableManager]
        [env.api.plugins.actions, @pluginManager]
        [env.api.database.actions, @database]
        [env.api.groups.actions, @groupManager]
        [env.api.pages.actions, @pageManager]
        [env.api.devices.actions, @deviceManager]
      ]

      onError = (error) =>
        env.logger.error(error.message)
        env.logger.debug(error)

      checkPermissions = (socket, action) =>
        hasPermission = no
        if action.permission? and action.permission.scope?
          hasPermission = @userManager.hasPermission(
            socket.username, 
            action.permission.scope, 
            action.permission.access
          )
        else if action.permission? and action.permission.action?
          hasPermission = @userManager.hasPermissionBoolean(
            socket.username,
            action.permission.action
          )
        else
          hasPermission = yes
        return hasPermission

      @io.on('connection', (socket) =>
        declapi.createSocketIoApi(socket, actionsWithBindings, onError, checkPermissions)
        username = socket.username
        role = @userManager.getUserByUsername(username).role
        permissions = @userManager.getPermissionsByUsername(username)
        socket.emit('hello', {
          username
          role
          permissions
        })
        if (
          @userManager.hasPermission(username, 'devices', 'read') or
          @userManager.hasPermission(username, 'pages', 'read')  
        )
          socket.emit('devices', (d.toJson() for d in @deviceManager.getDevices()) )
        else socket.emit('devices', [])

        if @userManager.hasPermission(username, 'rules', 'read')      
          socket.emit('rules', (r.toJson() for r in @ruleManager.getRules()) )
        else socket.emit('rules', [])

        if @userManager.hasPermission(username, 'rules', 'read')   
          socket.emit('variables', (v.toJson() for v in @variableManager.getVariables()) )
        else socket.emit('variables', [])

        if @userManager.hasPermission(username, 'pages', 'read')  
          socket.emit('pages',  @pageManager.getPages() )
        else socket.emit('pages', [])

        needsRules = (
          @userManager.hasPermission(username, 'devices', 'read') or
          @userManager.hasPermission(username, 'rules', 'read') or
          @userManager.hasPermission(username, 'variables', 'read') or
          @userManager.hasPermission(username, 'pages', 'read') or
          @userManager.hasPermission(username, 'groups', 'read')
        )
        if needsRules
          socket.emit('groups',  @groupManager.getGroups() )
        else socket.emit('groups', [])
      )

    listen: () ->
      genErrFunc = (serverConfig) => 
        return (err) =>
          msg = "Could not listen on port #{serverConfig.port}. Error: #{err.message}. "
          switch err.code 
            when "EACCES" then msg += "Are you root?."
            when "EADDRINUSE" then msg += "Is a server already running?"
            else msg = null
          if msg?
            env.logger.error msg
            env.logger.debug err.stack
            err.silent = yes  
          throw err

      listenPromises = []
      if @app.httpsServer?
        httpsServerConfig = @config.settings.httpsServer
        @app.httpsServer.on 'error', genErrFunc(@config.settings.httpsServer)
        awaiting = Promise.promisify(@app.httpsServer.listen, @app.httpsServer)(
          httpsServerConfig.port, httpsServerConfig.hostname
        )
        listenPromises.push awaiting.then( =>
          env.logger.info "listening for https-request on port #{httpsServerConfig.port}..."
        )
        
      if @app.httpServer?
        httpServerConfig = @config.settings.httpServer
        @app.httpServer.on 'error', genErrFunc(@config.settings.httpServer)
        awaiting = Promise.promisify(@app.httpServer.listen, @app.httpServer)(
          httpServerConfig.port, httpServerConfig.hostname
        )
        listenPromises.push awaiting.then( =>
          env.logger.info "listening for http-request on port #{httpServerConfig.port}..."
        )
        
      Promise.all(listenPromises).then( =>
        @emit "server listen", "startup"
      )

    restart: () ->
      unless process.env['PIMATIC_DAEMONIZED']?
        throw new Error(
          'Can not restart self, when not daemonized. ' +
          'Please run pimatic with: "node ' + process.argv[1] + ' start" to use this feature.'
        )
      # monitor will auto restart script
      process.nextTick -> 
        daemon = require 'daemon'
        env.logger.info("restarting...")
        daemon.daemon process.argv[1], process.argv[2..]
        process.exit 0

    getGuiSetttings: () -> {
      config: @config.settings.gui
      defaults: @config.settings.gui.__proto__
    }

    _emitDeviceAttributeEvent: (device, attributeName, attribute, time, value) ->
      @emit 'deviceAttributeChanged', {device, attributeName, attribute, time, value}
      @io?.emit(
        'deviceAttributeChanged', 
        {deviceId: device.id, attributeName, time: time.getTime(), value}
      )


    _emitDeviceEvent: (eventType, device) ->
      @emit(eventType, device)
      @io?.emit(eventType, device.toJson())

    _emitDeviceAdded: (device) -> @_emitDeviceEvent('deviceAdded', device)
    _emitDeviceChanged: (device) -> @_emitDeviceEvent('deviceChanged', device)
    _emitDeviceRemoved: (device) -> @_emitDeviceEvent('deviceRemoved', device)

    _emitDeviceOrderChanged: (deviceOrder) ->
      @_emitOrderChanged('deviceOrderChanged', deviceOrder)

    _emitMessageLoggedEvent: (level, msg, meta) ->
      @emit 'messageLogged', {level, msg, meta}
      @io?.emit 'messageLogged', {level, msg, meta}

    _emitOrderChanged: (eventName, order) ->
      @emit(eventName, order)
      @io?.emit(eventName, order)

    _emitPageEvent: (eventType, page) ->
      @emit(eventType, page)
      @io?.emit(eventType, page)

    _emitPageAdded: (page) -> @_emitPageEvent('pageAdded', page)
    _emitPageChanged: (page) -> @_emitPageEvent('pageChanged', page)
    _emitPageRemoved: (page) -> @_emitPageEvent('pageRemoved', page)
    _emitPageOrderChanged: (pageOrder) ->
      @_emitOrderChanged('pageOrderChanged', pageOrder)

    _emitGroupEvent: (eventType, group) ->
      @emit(eventType, group)
      @io?.emit(eventType, group)

    _emitGroupAdded: (group) -> @_emitGroupEvent('groupAdded', group)
    _emitGroupChanged: (group) -> @_emitGroupEvent('groupChanged', group)
    _emitGroupRemoved: (group) -> @_emitGroupEvent('groupRemoved', group)
    _emitGroupOrderChanged: (proupOrder) ->
      @_emitOrderChanged('groupOrderChanged', proupOrder)

    _emitRuleEvent: (eventType, rule) ->
      @emit(eventType, rule)
      @io?.emit(eventType, rule.toJson())

    _emitRuleAdded: (rule) -> @_emitRuleEvent('ruleAdded', rule)
    _emitRuleRemoved: (rule) -> @_emitRuleEvent('ruleRemoved', rule)
    _emitRuleChanged: (rule) -> @_emitRuleEvent('ruleChanged', rule)
    _emitRuleOrderChanged: (ruleOrder) ->
      @_emitOrderChanged('ruleOrderChanged', ruleOrder)

    _emitVariableEvent: (eventType, variable) ->
      @emit(eventType, variable)
      @io?.emit(eventType, variable.toJson())

    _emitVariableAdded: (variable) -> @_emitVariableEvent('variableAdded', variable)
    _emitVariableRemoved: (variable) -> @_emitVariableEvent('variableRemoved', variable)
    _emitVariableChanged: (variable) -> @_emitVariableEvent('variableChanged', variable)
    _emitVariableValueChanged: (variable, value) ->
      @emit("variableValueChanged", variable, value)
      @io?.emit("variableValueChanged", {
        variableName: variable.name
        variableValue: value
      })

    _emitVariableOrderChanged: (variableOrder) ->
      @_emitOrderChanged('variableOrderChanged', variableOrder)

    _emitUpdateProcessStatus: (status, info) ->
      @emit 'updateProcessStatus', status, info
      @io?.emit("updateProcessStatus", {
        status: status
        modules: info.modules
      }) 

    _emitUpdateProcessMessage: (message, info) ->
      @emit 'updateProcessMessages', message, info
      @io?.emit("updateProcessMessage", {
        message: message
        modules: info.modules
      }) 

    init: ->

      initVariables = =>
        @variableManager.init()
        @variableManager.on("variableChanged", (changedVar) =>
          for variable in @config.variables
            if variable.name is changedVar.name
              delete variable.value
              delete variable.expression
              switch changedVar.type
                when 'value' then variable.value = changedVar.value
                when 'expression' then variable.expression = changedVar.exprInputStr
              break
          @_emitVariableChanged(changedVar)
          @emit "config"
        )
        @variableManager.on("variableValueChanged", (changedVar, value) =>
          if changedVar.type is 'value'
            for variable in @config.variables
              if variable.name is changedVar.name
                variable.value = value
                break
            @emit "config"
          @_emitVariableValueChanged(changedVar, value)
          
        )
        @variableManager.on("variableAdded", (addedVar) =>
          switch addedVar.type
            when 'value' then @config.variables.push({
              name: addedVar.name, 
              value: addedVar.value
            })
            when 'expression' then @config.variables.push({
              name: addedVar.name, 
              expression: addedVar.exprInputStr
            })
          @_emitVariableAdded(addedVar)
          @emit "config"
        )
        @variableManager.on("variableRemoved", (removedVar) =>
          for variable, i in @config.variables
            if variable.name is removedVar.name
              @config.variables.splice(i, 1)
              break
          @_emitVariableRemoved(removedVar)
          @emit "config"
        )

      initActionProvider = =>
        defaultActionProvider = [
          env.actions.SwitchActionProvider
          env.actions.DimmerActionProvider
          env.actions.LogActionProvider
          env.actions.SetVariableActionProvider
          env.actions.ShutterActionProvider
          env.actions.StopShutterActionProvider
          env.actions.ToggleActionProvider
        ]
        for actProv in defaultActionProvider
          actProvInst = new actProv(this)
          @ruleManager.addActionProvider(actProvInst)

      initPredicateProvider = =>
        defaultPredicateProvider = [
          env.predicates.PresencePredicateProvider
          env.predicates.SwitchPredicateProvider
          env.predicates.DeviceAttributePredicateProvider
          env.predicates.VariablePredicateProvider
          env.predicates.VariableUpdatedPredicateProvider
          env.predicates.ContactPredicateProvider
          env.predicates.ButtonPredicateProvider
          env.predicates.DeviceAttributeWatchdogProvider
        ]
        for predProv in defaultPredicateProvider
          predProvInst = new predProv(this)
          @ruleManager.addPredicateProvider(predProvInst)

      initRules = =>

        addRulePromises = (for rule in @config.rules
          do (rule) =>
            unless rule.active? then rule.active = yes

            unless rule.id.match /^[a-z0-9\-_]+$/i
              newId = S(rule.id).slugify().s
              env.logger.warn """
                The id of the rule "#{rule.id}" contains a non alphanumeric letter or symbol.
                Changing the id of the rule to "#{newId}".
              """
              rule.id = newId

            unless rule.name? then rule.name = S(rule.id).humanize().s

            @ruleManager.addRuleByString(rule.id, {
              name: rule.name, 
              ruleString: rule.rule, 
              active: rule.active
              logging: rule.logging
            }, force = true).catch( (err) =>
              env.logger.error "Could not parse rule \"#{rule.rule}\": " + err.message 
              env.logger.debug err.stack
            )        
        )

        return Promise.all(addRulePromises).then(=>
          # Save rule updates to the config file:
          # 
          # * If a new rule was added then...
          @ruleManager.on "ruleAdded", (rule) =>
            # ...add it to the rules Array in the config.json file
            inConfig = (_.findIndex(@config.rules , {id: rule.id}) isnt -1)
            unless inConfig
              @config.rules.push {
                id: rule.id
                name: rule.name
                rule: rule.string
                active: rule.active
                logging: rule.logging
              }
            @_emitRuleAdded(rule)
            @emit "config"
          # * If a rule was changed then...
          @ruleManager.on "ruleChanged", (rule) =>
            # ...change the rule with the right id in the config.json file
            @config.rules = for r in @config.rules 
              if r.id is rule.id
                {
                  id: rule.id, 
                  name: rule.name,
                  rule: rule.string,
                  active: rule.active,
                  logging: rule.logging
                }
              else r
            @_emitRuleChanged(rule)
            @emit "config"
          # * If a rule was removed then
          @ruleManager.on "ruleRemoved", (rule) =>
            # ...Remove the rule with the right id in the config.json file
            @config.rules = (r for r in @config.rules when r.id isnt rule.id)
            @_emitRuleRemoved(rule)
            @emit "config"
        )

      return @database.init()
        .then( => @pluginManager.loadPlugins() )
        .then( => @pluginManager.initPlugins() )
        .then( => @deviceManager.initDevices() )
        .then( => @deviceManager.loadDevices() )
        .then(initVariables)
        .then(initActionProvider)
        .then(initPredicateProvider)
        .then(initRules)
        .then( =>         
          # Save the config on "config" event
          @on "config", =>
            @saveConfig()

          context = 
            waitFor: []
            waitForIt: (promise) -> @waitFor.push promise

          @emit "after init", context

          Promise.all(context.waitFor).then => @listen()
        )

    _initRestApi: ->
      onError = (error) =>
        if error instanceof Error
          message = error.message
          env.logger.error error.message
          env.logger.debug error.stack

      @app.get("/api/device/:deviceId/:actionName", (req, res, next) =>
        username = req.session.username
        hasPermission = @userManager.hasPermissionBoolean(
          username, 'controlDevices'
        )

        if hasPermission
          deviceId = req.params.deviceId
          actionName = req.params.actionName
          device = @deviceManager.getDeviceById(deviceId)
          if device?
            if device.hasAction(actionName)
              action = device.actions[actionName]
              declapi.callActionFromReqAndRespond(actionName, action, device, req, res)
            else
              declapi.sendErrorResponse(res, 'device hasn\'t that action')
          else declapi.sendErrorResponse(res, 'device not found')
        else
          res.send(403)
      )

      @app.get("/api", (req, res, nest) => res.send(declapi.stringifyApi(env.api.all)) )
      @app.get("/api/decl-api-client.js", declapi.serveClient)

      createPermissionCheck = (app, actions) =>
        for actionName, action of actions
          do (actionName, action) =>
            if action.rest? and action.permission?
              type = (action.rest.type or 'get').toLowerCase()
              url = action.rest.url
              app[type](url, (req, res, next) =>
                username = req.session.username
                if action.permission.scope?
                  hasPermission = @userManager.hasPermission(
                    username, 
                    action.permission.scope, 
                    action.permission.access
                  )
                else if action.permission.action?
                  hasPermission = @userManager.hasPermissionBoolean(
                    username,
                    action.permission.action
                  )
                else
                  throw new Error("Unknown permission declaration for action #{action}")
                if hasPermission is yes
                  next()
                else
                  res.send(403)
              )

      createPermissionCheck(@app, env.api.framework.actions)
      createPermissionCheck(@app, env.api.rules.actions)
      createPermissionCheck(@app, env.api.variables.actions)
      createPermissionCheck(@app, env.api.plugins.actions)
      createPermissionCheck(@app, env.api.database.actions)
      createPermissionCheck(@app, env.api.groups.actions)
      createPermissionCheck(@app, env.api.pages.actions)
      createPermissionCheck(@app, env.api.devices.actions)
      declapi.createExpressRestApi(@app, env.api.framework.actions, this, onError)
      declapi.createExpressRestApi(@app, env.api.rules.actions, this.ruleManager, onError)
      declapi.createExpressRestApi(@app, env.api.variables.actions, this.variableManager, onError)
      declapi.createExpressRestApi(@app, env.api.plugins.actions, this.pluginManager, onError)
      declapi.createExpressRestApi(@app, env.api.database.actions, this.database, onError)
      declapi.createExpressRestApi(@app, env.api.groups.actions, this.groupManager, onError)
      declapi.createExpressRestApi(@app, env.api.pages.actions, this.pageManager, onError)
      declapi.createExpressRestApi(@app, env.api.devices.actions, this.deviceManager, onError)

    saveConfig: ->
      assert @config?
      try
        fs.writeFileSync @configFile, JSON.stringify(@config, null, 2)
      catch err
        env.logger.error "Could not write config file: ", err.message
        env.logger.debug err
        env.logger.info "config.json updated"

  return { Framework }
