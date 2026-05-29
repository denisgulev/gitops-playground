function handler(event) {
    const request = event.request;
    const hostHeader = request.headers.host.value;

    if (hostHeader.startsWith('www.')) {
        // Strip 'www.' and redirect to a non-www version
        const rootDomain = hostHeader.substring(4); // Remove 'www.'

        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                "location": { "value": "https://" + rootDomain + request.uri },
                "cache-control": { "value": "max-age=3600" }
            }
        };
    }

    // If it doesn't start with 'www.', proceed normally
    return request;
}