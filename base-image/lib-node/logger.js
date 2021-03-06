const winston = require('winston');
const date_time = require('moment-timezone');
const on_headers = require('on-headers');
const on_finished = require('on-finished');
// const continuation_local_storage = require('continuation-local-storage');
const continuation_local_storage = require('cls-hooked');
const Promise = require('bluebird');
const continuation_local_storage_bluebird = require('cls-bluebird');
const redis = require('redis');
const continuation_local_storage_redis = require('cls-redis');
var appName = undefined;
var Sequelize = require('sequelize');

const winston_config = winston.config;

var winstonLogger = new winston.Logger({
  transports: [
    new winston.transports.Console({
        level : process.env.STAGE === 'prod' ? 'info' : 'debug',
        showLevel : false
    } )
  ],
  exitOnError: false
});


var getNamespace = continuation_local_storage.getNamespace;
var createNamespace = continuation_local_storage.createNamespace;
var createRequest = createNamespace( 'Request-Id' );
var getRequest = getNamespace( 'Request-Id' );
continuation_local_storage_bluebird( createRequest );
continuation_local_storage_redis( createRequest );
Sequelize.useCLS( createRequest );

function logger() {
}

logger.prototype.log = function( level, ...message ) {
    // body...
    var combinedMessage = combineMessage( message );
    winstonLogger.log( formatterMessage( level, combinedMessage ) );
};

logger.prototype.info = function( ...message ) {
    // body...
    var combinedMessage = combineMessage( message );
    winstonLogger.info( formatterMessage( 'info', combinedMessage ) );
};

logger.prototype.debug = function( ...message ) {
    // body...
    var combinedMessage = combineMessage( message );
    winstonLogger.debug( formatterMessage( 'debug', combinedMessage ) );
};

logger.prototype.error = function( ...message ) {
    // body...
    var combinedMessage = combineMessage( message );
    winstonLogger.error( formatterMessage( 'error', combinedMessage ) );
};

logger.prototype.getNamespace = function() {
    // body...
    return getRequest;
};

logger.prototype.useSequelizeCls = function( serviceSequelize ) {
    // body...
    serviceSequelize.useCLS( createRequest );
    Sequelize = serviceSequelize;
    return serviceSequelize;
};

logger.prototype.logger = function( appNameLocal ) { 
    // var createRequest = createNamespace( 'Request-Id' );
    // continuation_local_storage_bluebird( createRequest );
    // continuation_local_storage_redis( createRequest );
    // Sequelize.useCLS(createRequest);
    return function( req, res, next ) {
        // create requestId and append it in header as Request-Id...
        appName = appNameLocal;
        createRequest.run( function( context ) {
            req._logStartTime = process.hrtime();
            on_finished( res, function() {
                res._logEndTime = process.hrtime();
                res._logDiffTime = process.hrtime( req._logStartTime );
                winstonLogger.info( formatterHTTP( 'info', req, res ) );
            } );

            var requestId = req.get( 'Request-Id' ) || req.headers[ 'Request-Id' ] || '';
            // createRequest.bindEmitter( req );
            // createRequest.bindEmitter( res );
            createRequest.set( 'Request-Id', requestId );
            if( requestId === '' ) {
                winstonLogger.error( formatterMessage( 'error', 'Request-Id not found in headers.' ) )
            }
            next();
        } );
    };
};

function formatterMessage( logLevel, message ) {
    var timestamp = dateTimeIST();
    logLevel = getLogLevel( logLevel );
    var requestId = getRequestId();
    var serviceName = getServiceName();
    var formattedMessage = `[${ timestamp }] [${ logLevel }] [${ requestId }] [${ serviceName }] ${ message }`;
    return formattedMessage;
}

function dateTimeIST() {
    return `${ date_time( new Date() ).tz('Asia/Kolkata').format('YYYY-MM-DD HH:mm:ss.SSS') }`;
}

function getLogLevel( logLevel ) {
    return logLevel.toLowerCase();
}

function getRequestId() {
    // var getRequest = getNamespace( 'Request-Id' );
    return getRequest.get( 'Request-Id' ) || '';
    // return getRequest && getRequest.get( 'Request-Id' ) ? getRequest.get( 'Request-Id' ) : '';
}

function getRequestIdAfterFinished( req ) {
    return ( req.get( 'Request-Id' ) || req.headers[ 'Request-Id' ] || '' );
}

function getServiceName() {
    return appName || process.env.APP_NAME || 'local';
}

function formatterHTTP( logLevel, req, res ) {
    var timestamp = dateTimeIST();
    logLevel = getLogLevel( logLevel );
    var requestId = getRequestIdAfterFinished( req );
    var serviceName = getServiceName();
    var httpMessage = buildHTTPMessage( req, res );
    var formattedHTTPMessage = `[${ timestamp }] [${ logLevel }] [${ requestId }] [${ serviceName }] ${ httpMessage }`;
    return formattedHTTPMessage;
}

function buildHTTPMessage( req, res ) {
    return `[${ req.method }] [${ req.originalUrl || req.url }] [${ res.getHeader( 'Content-Length' ) ? res.statusCode : 504 }] [${ res.getHeader( 'Content-Length' ) || 0 }] [${ ( ( res._logEndTime[ 0 ] - req._logStartTime[ 0 ] ) * 1e3 + ( res._logEndTime[ 1 ] - req._logStartTime[ 1 ] ) * 1e-6 ).toFixed(3) }ms]`;
}

function combineMessage( message ) {
    return message.join( ' ' );
}

module.exports = new logger();