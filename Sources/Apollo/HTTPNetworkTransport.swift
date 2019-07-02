import Foundation

extension URLSessionTask: Cancellable {}

/// A transport-level, HTTP-specific error.
public struct GraphQLHTTPResponseError: Error, LocalizedError {
  public enum ErrorKind {
    case errorResponse
    case invalidResponse
    
    var description: String {
      switch self {
      case .errorResponse:
        return "Received error response"
      case .invalidResponse:
        return "Received invalid response"
      }
    }
  }
  
  /// The body of the response.
  public let body: Data?
  /// Information about the response as provided by the server.
  public let response: HTTPURLResponse
  public let kind: ErrorKind
  
  public init(body: Data? = nil, response: HTTPURLResponse, kind: ErrorKind) {
    self.body = body
    self.response = response
    self.kind = kind
  }
  
  public var bodyDescription: String {
    if let body = body {
      if let description = String(data: body, encoding: response.textEncoding ?? .utf8) {
        return description
      } else {
        return "Unreadable response body"
      }
    } else {
      return "Empty response body"
    }
  }
  
  public var errorDescription: String? {
    return "\(kind.description) (\(response.statusCode) \(response.statusCodeDescription)): \(bodyDescription)"
  }
}

/// A network transport that uses HTTP POST requests to send GraphQL operations to a server, and that uses `URLSession` as the networking implementation.
public class HTTPNetworkTransport: NetworkTransport {
  
  let url: URL
  var session: URLSession
  let serializationFormat = JSONSerializationFormat.self
  
  private let _enableAutoPersistedQueries: Bool
  private let _useHttpGetMethodForPersistedQueries: Bool
  
  /// Creates a network transport with the specified server URL and session configuration.
  ///
  /// - Parameters:
  ///   - url: The URL of a GraphQL server to connect to.
  ///   - configuration: A session configuration used to configure the session. Defaults to `URLSessionConfiguration.default`.
  ///   - enableAutoPersistedQueries: Whether to send persistedQuery extension. QueryDocument will be absent at 1st request, retry with QueryDocument if server respond PersistedQueryNotFound or PersistedQueryNotSupport. Defaults to false.
  ///   - useHttpGetMethodForPersistedQueries: Whether to send PersistedQuery supported request with HTTPGETMethod, retry with HTTPPOSTMethod if PersistedQuery not support/not found in server.
  public init(url: URL, configuration: URLSessionConfiguration = URLSessionConfiguration.default,
              enableAutoPersistedQueries: Bool = false,
              useHttpGetMethodForPersistedQueries: Bool = false
    ) {
    self.url = url
    self.session = URLSession(configuration: configuration)
    self._enableAutoPersistedQueries = enableAutoPersistedQueries
    self._useHttpGetMethodForPersistedQueries = useHttpGetMethodForPersistedQueries
  }
  
  /// Send a GraphQL operation to a server and return a response.
  ///
  /// - Parameters:
  ///   - operation: The operation to send.
  ///   - completionHandler: A closure to call when a request completes.
  ///   - response: The response received from the server, or `nil` if an error occurred.
  ///   - error: An error that indicates why a request failed, or `nil` if the request was succesful.
  /// - Returns: An object that can be used to cancel an in progress request.
  public func send<Operation>(operation: Operation, completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) -> Cancellable {
    
    let headers = decorateRequestHeaders(for: operation)
    
    let request = { () -> URLRequest in
      guard operation.operationType == .query, _enableAutoPersistedQueries else {
        // not support APQs
        return httpPostRequest(operation: operation, requestHeaders: headers, sendQueryDocument: true, autoPersistQueries: false)
      }
      
      // support APQs
      if _useHttpGetMethodForPersistedQueries {
        return httpGetRequest(operation: operation, requestHeaders: headers, sendQueryDocument: false, autoPersistQueries: true)
      } else {
        return httpPostRequest(operation: operation, requestHeaders: headers, sendQueryDocument: false, autoPersistQueries: true)
      }
    }()
    
    let task = session.dataTask(with: request) { [weak self] (data: Data?, httpResponse: URLResponse?, httpError: Error?) in
      guard let self = self else { return }
      
      let result = self.handleResponse(data, httpResponse, httpError)
      guard let body = result.0 else {
        completionHandler(nil, result.1)
        return
      }
      
      if let error = body["errors"] as? [JSONObject],
        let errorMsg = error.filter ({ $0["message"] as? String != nil }).first?["message"] as? String {
        
        // error handling
        switch errorMsg {
        case "PersistedQueryNotFound", "PersistedQueryNotSupported":
          // retry with standard call
          let requestRetry = { () -> URLRequest in
            guard operation.operationType == .query, self._enableAutoPersistedQueries else {
              // fallback to normal call
              return self.httpPostRequest(operation: operation, requestHeaders: headers, sendQueryDocument: true, autoPersistQueries: false)
            }
            
            // retry if type==query and with apqs enabled, send query with apq extension
            return self.httpPostRequest(operation: operation, requestHeaders: headers, sendQueryDocument: true, autoPersistQueries: true)
          }()
          
          let newSession = URLSession(configuration: self.session.configuration)
          let (dataRetry, responseRetry, errorRetry) = newSession.synchronousDataTask(with: requestRetry)
          
          let result = self.handleResponse(dataRetry, responseRetry, errorRetry)
          guard let bodyRetry = result.0 else {
            completionHandler(nil, result.1)
            return
          }
          
          let response = GraphQLResponse(operation: operation, body: bodyRetry)
          completionHandler(response, nil)
        default:
          // unable to process, pass through to upper level
          let response = GraphQLResponse(operation: operation, body: body)
          completionHandler(response, nil)
        }
      }else {
        // no errors
        let response = GraphQLResponse(operation: operation, body: body)
        completionHandler(response, nil)
      }
    }
    
    task.resume()
    return task
  }
  
  // MARKL: Helper
  private func handleResponse(_ data: Data?,_ httpResponse: URLResponse?,_ error: Error?) -> (JSONObject?, Error?) {
    
    if error != nil {
      return (nil, error)
    }
    
    guard let httpResponse = httpResponse as? HTTPURLResponse else {
      fatalError("Response should be an HTTPURLResponse")
    }
    
    if (!httpResponse.isSuccessful) {
      return (nil, GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .errorResponse))
    }
    
    guard let data = data else {
      return (nil, GraphQLHTTPResponseError(body: nil, response: httpResponse, kind: .invalidResponse))
    }
    
    do {
      guard let body =  try self.serializationFormat.deserialize(data: data) as? JSONObject else {
        throw GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .invalidResponse)
      }
      return (body, nil)
      
    } catch {
      return (nil, error)
    }
  }
  
  private func httpPostRequest<Operation: GraphQLOperation>(operation: Operation,
                                                            requestHeaders: [String: String?],
                                                            sendQueryDocument: Bool,
                                                            autoPersistQueries: Bool) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    _ = requestHeaders.compactMap ({ request.setValue($1, forHTTPHeaderField: $0) })
    let body = requestBody(for: operation, sendQueryDocument: sendQueryDocument, autoPersistQueries: autoPersistQueries)
    
    request.httpBody = try! serializationFormat.serialize(value: body)
    
    return request
  }
  
  private func httpGetRequest<Operation: GraphQLOperation>(operation: Operation,
                                                           requestHeaders: [String: String?],
                                                           sendQueryDocument: Bool,
                                                           autoPersistQueries: Bool) -> URLRequest {
    
    var urlComponent = URLComponents.init(url: url, resolvingAgainstBaseURL: true)
    urlComponent?.queryItems = requestURLQueryItems(for: operation, sendQueryDocument: sendQueryDocument, autoPersistQueries: autoPersistQueries)
    
    guard let newUrl = urlComponent?.url else {
      preconditionFailure("To send data via urlQueryUrl, URL construction must be valid")
    }
    
    var request = URLRequest(url: newUrl)
    request.httpMethod = "GET"
    _ = requestHeaders.compactMap ({ request.setValue($1, forHTTPHeaderField: $0) })
    
    return request
  }
  
  private func requestBody<Operation: GraphQLOperation>(for operation: Operation,
                                                        sendQueryDocument: Bool,
                                                        autoPersistQueries: Bool) -> GraphQLMap {
    
    var payload: GraphQLMap = [:]
    
    if autoPersistQueries {
      guard let operationIdentifier = operation.operationIdentifier else {
        preconditionFailure("To enabled autoPersistQueries, Apollo types must be generated with operationIdentifiers")
      }
      payload["extensions"] = [
        "persistedQuery" : ["sha256Hash": operationIdentifier, "version": 1]
      ]
    }
    
    if let variables = operation.variables?.compactMapValues({ $0 }), variables.count > 0 {
      payload["variables"] = variables
    }
    
    if sendQueryDocument {
      // TODO: This work-around fix "operationId is invalid for swift codegen" (https://github.com/apollographql/apollo-tooling/issues/1362), please remove this work-around after it's fixed.
      let modifiedQuery = operation.queryDocument.replacingOccurrences(of: "fragment", with: "\nfragment")
      payload["query"] = modifiedQuery
    }
    
    return payload
  }
  
  private func requestURLQueryItems<Operation: GraphQLOperation>(for operation: Operation,
                                                                 sendQueryDocument: Bool,
                                                                 autoPersistQueries: Bool) -> [URLQueryItem] {
    
    var queryItems: [URLQueryItem] = []
    
    let body = requestBody(for: operation, sendQueryDocument: sendQueryDocument, autoPersistQueries: autoPersistQueries)
    
    _ = body.compactMap({ arg in
      if let value = arg.value as? GraphQLMap {
        do {
          let data = try serializationFormat.serialize(value: value)
          if let string = String(data: data, encoding: String.Encoding.utf8) {
            queryItems.append(URLQueryItem(name: arg.key, value: string))
          }
        } catch {
          print(error)
        }
      }
      
      if let string = arg.value as? String {
        queryItems.append(URLQueryItem(name: arg.key, value: string))
      }
    })
    
    return queryItems
  }
  
  private func decorateRequestHeaders<Operation: GraphQLOperation>(for operation: Operation) -> [String: String?] {
    return ["Content-Type": "application/json",
            "X-APOLLO-OPERATION-ID": operation.operationIdentifier
    ]
  }
}

extension URLSession {
  func synchronousDataTask(with request: URLRequest) -> (Data?, URLResponse?, Error?) {
    var data: Data?
    var response: URLResponse?
    var error: Error?
    
    let semaphore = DispatchSemaphore(value: 0)
    
    let dataTask = self.dataTask(with: request) {
      data = $0
      response = $1
      error = $2
      
      semaphore.signal()
    }
    dataTask.resume()
    
    _ = semaphore.wait(timeout: .distantFuture)
    
    return (data, response, error)
  }
}

