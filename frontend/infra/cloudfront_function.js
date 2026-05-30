function handler(event) {
    var request = event.request;
    var hostHeader = request.headers.host && request.headers.host.value;

    if (hostHeader && hostHeader.indexOf('www.') === 0) {
        var rootDomain = hostHeader.substring(4);

        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                "location": { "value": "https://" + rootDomain + request.uri },
                "cache-control": { "value": "max-age=3600" }
            }
        };
    }

    return request;
}