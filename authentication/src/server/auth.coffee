derby = require('derby')
everyauth = require('everyauth')

req = undefined
model = undefined
sess = undefined

module.exports = {
  setupStore: (store) ->
    setupQueries(store)
    setupAccessControl(store)
    setupEveryauth()
  middleware: (request, res, next) ->
    req = request
    model = req.getModel()
    sess = model.session
    newUser()
    next()
}

setupQueries = (store) ->
  ## Setup Queries
  store.query.expose 'users', 'withId', (id) ->
    @byId(id)
  store.query.expose 'users', 'withEveryauth', (provider, id) ->
    console.log {withEveryauth:{provider:provider,id:id}}
    @where("auth.#{provider}.id").equals(id)
  store.queryAccess 'users', 'withEveryauth', (methodArgs) ->
    accept = arguments[arguments.length-1]
    accept(true) #for now

setupAccessControl = (store) ->
  store.accessControl = true
  
  # Callback signatures here have variable length, eg `callback(captures..., next)` 
  # Is using arguments[n] the correct way to handle this?  

  store.readPathAccess 'users.*', () -> #captures, next) ->
    return unless @session && @session.userId # https://github.com/codeparty/racer/issues/37
    captures = arguments[0]
    next = arguments[arguments.length-1]
    # console.log { readPathAccess: {captures:captures, sessionUserId:@session.userId, next:next} }
    next(captures == @session.userId)
    
  store.writeAccess '*', 'users.*', () -> #captures, value, next) ->
    return unless @session && @session.userId
    captures = arguments[0]
    next = arguments[arguments.length-1]
    pathArray = captures.split('.')
    # console.log { writeAccess: {captures:captures, next:next, pathArray:pathArray, arguments:arguments} }
    next(pathArray[0] == @session.userId)

## -------- New user --------
# They get to play around before creating a new account.
newUser = ->
  unless sess.userId
    sess.userId = derby.uuid()
    model.set "users.#{sess.userId}", {auth:{}}
  
setupEveryauth = ->
  everyauth.debug = true
  
  everyauth.everymodule.findUserById (id, callback) ->
    # will never be called, can't fetch user from database at this point on the server
    # see https://github.com/codeparty/racer/issues/39. Handled in app/auth.coffee for now
    callback null, null
  
  ## Facebook Authentication Logic
  ## -----------------------------
  everyauth
    .facebook
    .appId(process.env.FACEBOOK_KEY)
    .appSecret(process.env.FACEBOOK_SECRET)
    .findOrCreateUser( (session, accessToken, accessTokenExtra, fbUserMetadata) ->

      # Put it in the session for later use
      session.auth ||= {}
      session.auth.facebook = fbUserMetadata.id

      model = req.getModel()
      q = model.query('users').withEveryauth('facebook', fbUserMetadata.id)
      model.fetch q, (err, user) ->
        console.log {err:err, fbUserMetadata:fbUserMetadata}
        id = user && (u = user.get()) && u.length>0 && u[0].id
        # Has user been tied to facebook account already?
        if (id && id!=session.userId)
          session.userId = id
        # Else tie user to their facebook account
        else
          model.setNull "users.#{session.userId}.auth", {'facebook':{}}
          model.set "users.#{session.userId}.auth.facebook", fbUserMetadata

      fbUserMetadata
  ).redirectPath "/"

  everyauth.everymodule.handleLogout (req, res) ->
    if req.session.auth && req.session.auth.facebook
      req.session.auth.facebook = undefined
    req.session.userId = undefined
    req.logout() # The logout method is added for you by everyauth, too
    @redirect res, @logoutRedirectPath()
