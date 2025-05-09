function handler(event) {
    var request = event.request;
    var uri = request.uri;

    if (uri === "/grafana") {
        return {
            statusCode: 301,
            statusDescription: "Moved Permanently",
            headers: {
                location: { value: "/grafana/" }
            }
        };
    }

    return request;
}