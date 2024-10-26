//
//  Router.swift
//
//
//  Created by Evan Anderson on 10/17/24.
//

import DestinyUtilities
import Foundation
import HTTPTypes
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum Router: ExpressionMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        var returnType: RouterReturnType = .staticString
        var version: String = "HTTP/1.1"
        var middleware: [StaticMiddleware] = []
        var routes: [Route] = []
        for argument in node.as(MacroExpansionExprSyntax.self)!.arguments.children(viewMode: .all) {
            if let child: LabeledExprSyntax = argument.as(LabeledExprSyntax.self) {
                if let key: String = child.label?.text {
                    switch key {
                    case "returnType":
                        returnType = RouterReturnType(
                            rawValue: child.expression.memberAccess!.declName.baseName.text)!
                        break
                    case "version":
                        version = child.expression.stringLiteral!.string
                        break
                    case "middleware":
                        middleware = parse_middleware(child.expression.array!.elements)
                        break
                    default:
                        break
                    }
                } else if let function: FunctionCallExprSyntax = child.expression.functionCall {  // route
                    routes.append(parse_route(function))
                }
            }
        }
        let get_returned_type: (String) -> String
        func bytes<T: FixedWidthInteger>(_ bytes: [T]) -> String {
            return "[" + bytes.map({ "\($0)" }).joined(separator: ",") + "]"
        }
        func response(valueType: String, _ string: String) -> String {
            return "RouteResponse" + valueType + "(" + string + ")"
        }
        switch returnType {
        case .uint8Array:
            get_returned_type = { response(valueType: "UInt8Array", bytes([UInt8]($0.utf8))) }
        case .uint16Array:
            get_returned_type = { response(valueType: "UInt16Array", bytes([UInt16]($0.utf16))) }
        case .data:
            get_returned_type = { response(valueType: "Data", bytes([UInt8]($0.utf8))) }
        case .unsafeBufferPointer:
            get_returned_type = {
                response(
                    valueType: "UnsafeBufferPointer",
                    "StaticString(\"" + $0 + "\").withUTF8Buffer { $0 }")
            }
        case .staticString:
            get_returned_type = { response(valueType: "StaticString", "\"" + $0 + "\"") }
        }
        let static_responses: String = routes.map({
            let value: String = get_returned_type(
                $0.response(version: version, middleware: middleware))
            var string: String = $0.method.rawValue + " /" + $0.path + " " + version
            var length: Int = 32
            var buffer: String = ""
            string.withUTF8 { p in
                let amount: Int = min(p.count, length)
                for i in 0..<amount {
                    buffer += (i == 0 ? "" : ", ") + "\(p[i])"
                }
                length -= amount
            }
            for _ in 0..<length {
                buffer += ", 0"
            }
            return "StackString32(\(buffer)):" + value
        }).joined(separator: ",")
        return
            "\(raw: "Router(staticResponses: [" + (static_responses.isEmpty ? ":" : static_responses) + "])")"
    }
}

// MARK: Parse Router
/*
extension Router {
    static func parse_router(_ node: some FreestandingMacroExpansionSyntax) -> DestinyUtilities.Router {
        var returnType:RouterReturnType = .staticString
        var version:String = "HTTP/1.1"
        var middleware:[Middleware] = [], routes:[Route] = []
        for argument in node.as(MacroExpansionExprSyntax.self)!.arguments.children(viewMode: .all) {
            if let child:LabeledExprSyntax = argument.as(LabeledExprSyntax.self) {
                if let key:String = child.label?.text {
                    switch key {
                        case "returnType":
                            returnType = RouterReturnType(rawValue: child.expression.memberAccess!.declName.baseName.text)!
                            break
                        case "version":
                            version = child.expression.stringLiteral!.string
                            break
                        case "middleware":
                            middleware = parse_middleware(child.expression.array!.elements)
                            break
                        default:
                            break
                    }
                } else if let function:FunctionCallExprSyntax = child.expression.functionCall { // route
                    routes.append(parse_route(function))
                }
            }
        }
        let get_returned_type:(String) -> RouteResponseProtocol
        switch returnType {
            case .uint8Array:
                get_returned_type = { RouteResponseUInt8Array([UInt8]($0.description.utf8)) }
                break
            case .uint16Array:
                get_returned_type = { RouteResponseUInt16Array([UInt16]($0.description.utf16)) }
                break
            case .data:
                get_returned_type = { RouteResponseData(Data([UInt8]($0.description.utf8))) }
                break
            default:
                get_returned_type = { RouteResponseString($0) }
                break
        }
        var static_responses:[Substring:RouteResponseProtocol] = [:]
        for route in routes {
            let response:String = route.response(returnType: returnType, version: version, middleware: middleware)
            static_responses[route.method.rawValue + " /" + route.path] = RouteResponseString(response)
        }
        return DestinyUtilities.Router(staticResponses: static_responses)
    }
}*/

// MARK: Parse Middleware
extension Router {
    static func parse_middleware(_ array: ArrayElementListSyntax) -> [StaticMiddleware] {
        var middleware: [StaticMiddleware] = []
        for element in array {
            if let function: FunctionCallExprSyntax = element.expression.functionCall {
                var appliesToMethods: Set<HTTPRequest.Method> = []
                var appliesToStatuses: Set<HTTPResponse.Status> = []
                var appliesToContentTypes: Set<Route.ContentType> = []
                var appliesStatus: HTTPResponse.Status? = nil
                var appliesHeaders: [String: String] = [:]
                for argument in function.arguments {
                    switch argument.label!.text {
                    case "appliesToMethods":
                        appliesToMethods = Set(
                            argument.expression.array!.elements.map({
                                HTTPRequest.Method(
                                    rawValue:
                                        "\($0.expression.memberAccess!.declName.baseName.text)"
                                        .uppercased())!
                            }))
                    case "appliesToStatuses":
                        appliesToStatuses = Set(
                            argument.expression.array!.elements.map({
                                parse_status($0.expression.memberAccess!.declName.baseName.text)
                            }))
                    case "appliesToContentTypes":
                        appliesToContentTypes = Set(
                            argument.expression.array!.elements.map({
                                Route.ContentType(
                                    rawValue:
                                        "\($0.expression.memberAccess!.declName.baseName.text)")!
                            }))
                    case "appliesStatus":
                        appliesStatus = parse_status(
                            argument.expression.memberAccess!.declName.baseName.text)
                    case "appliesHeaders":
                        let dictionary: [(String, String)] = argument.expression.dictionary!.content
                            .as(DictionaryElementListSyntax.self)!.map({
                                ($0.key.stringLiteral!.string, $0.value.stringLiteral!.string)
                            })
                        for (key, value) in dictionary {
                            appliesHeaders[key] = value
                        }
                    default:
                        break
                    }
                }
                middleware.append(
                    StaticMiddleware(
                        appliesToMethods: appliesToMethods,
                        appliesToStatuses: appliesToStatuses,
                        appliesToContentTypes: appliesToContentTypes,
                        appliesStatus: appliesStatus,
                        appliesHeaders: appliesHeaders
                    )
                )
            }
        }
        return middleware
    }
}

// MARK: Parse Route
extension Router {
    static func parse_route(_ syntax: FunctionCallExprSyntax) -> Route {
        var method: HTTPRequest.Method = .get
        var path: String = ""
        var status: HTTPResponse.Status? = nil
        var contentType: Route.ContentType = .text
        var charset: String = "UTF-8"
        var staticResult: Route.Result? = nil
        for argument in syntax.arguments {
            let key: String = argument.label!.text
            switch key {
            case "method":
                method = HTTPRequest.Method(
                    rawValue: "\(argument.expression.memberAccess!.declName.baseName.text)"
                        .uppercased())!
            case "path":
                path = argument.expression.stringLiteral!.string
            case "status":
                status = parse_status(argument.expression.memberAccess!.declName.baseName.text)
            case "contentType":
                contentType = Route.ContentType(
                    rawValue: argument.expression.memberAccess!.declName.baseName.text)!
            case "charset":
                charset = argument.expression.stringLiteral!.string
            case "staticResult":
                guard let function: FunctionCallExprSyntax = argument.expression.functionCall else {
                    staticResult = nil
                    break
                }
                switch function.calledExpression.memberAccess!.declName.baseName.text {
                case "string":
                    staticResult = .string(
                        function.arguments.first!.expression.stringLiteral!.string)
                case "bytes":
                    staticResult = .bytes(
                        (function.arguments.first!.expression.array?.elements ?? []).compactMap(
                            {
                                return UInt8(
                                    $0.expression.as(IntegerLiteralExprSyntax.self)?
                                        .literal.text ?? "")
                            }))
                default: break
                }
            case "dynamicResult": // Find a way to call this function
                guard let closure = argument.expression.as(ClosureExprSyntax.self) else {
                    break
                }
            default:
                break
            }
        }
        return Route(
            method: method, path: path, status: status, contentType: contentType, charset: charset,
            staticResult: staticResult, dynamicResult: nil)
    }

    // MARK: Parse Status
    static func parse_status(_ key: String) -> HTTPResponse.Status {
        switch key {
        case "continue": return .continue
        case "switchingProtocols": return .switchingProtocols
        case "earlyHints": return .earlyHints
        case "ok": return .ok
        case "created": return .created
        case "accepted": return .accepted
        case "nonAuthoritativeInformation": return .nonAuthoritativeInformation
        case "noContent": return .noContent
        case "resetContent": return .resetContent
        case "partialContent": return .partialContent

        case "multipleChoices": return .multipleChoices
        case "movedPermanently": return .movedPermanently
        case "found": return .found
        case "seeOther": return .seeOther
        case "notModified": return .notModified
        case "temporaryRedirect": return .temporaryRedirect
        case "permanentRedirect": return .permanentRedirect

        case "badRequest": return .badRequest
        case "unauthorized": return .unauthorized
        case "forbidden": return .forbidden
        case "notFound": return .notFound
        case "methodNotAllowed": return .methodNotAllowed
        case "notAcceptable": return .notAcceptable
        case "proxyAuthenticationRequired": return .proxyAuthenticationRequired
        case "requestTimeout": return .requestTimeout
        case "conflict": return .conflict
        case "gone": return .gone
        case "lengthRequired": return .lengthRequired
        case "preconditionFailed": return .preconditionFailed
        case "contentTooLarge": return .contentTooLarge
        case "uriTooLong": return .uriTooLong
        case "unsupportedMediaType": return .unsupportedMediaType
        case "rangeNotSatisfiable": return .rangeNotSatisfiable
        case "expectationFailed": return .expectationFailed
        case "misdirectedRequest": return .misdirectedRequest
        case "unprocessableContent": return .unprocessableContent
        case "tooEarly": return .tooEarly
        case "upgradeRequired": return .upgradeRequired
        case "preconditionRequired": return .preconditionRequired
        case "tooManyRequests": return .tooManyRequests
        case "requestHeaderFieldsTooLarge": return .requestHeaderFieldsTooLarge
        case "unavailableForLegalReasons": return .unavailableForLegalReasons

        case "internalServerError": return .internalServerError
        case "notImplemented": return .notImplemented
        case "badGateway": return .badGateway
        case "serviceUnavailable": return .serviceUnavailable
        case "gatewayTimeout": return .gatewayTimeout
        case "httpVersionNotSupported": return .httpVersionNotSupported
        case "networkAuthenticationRequired": return .networkAuthenticationRequired

        default: return .internalServerError
        }
    }
}

// MARK: Misc
extension SyntaxProtocol {
    var functionCall: FunctionCallExprSyntax? { self.as(FunctionCallExprSyntax.self) }
    var stringLiteral: StringLiteralExprSyntax? { self.as(StringLiteralExprSyntax.self) }
    var memberAccess: MemberAccessExprSyntax? { self.as(MemberAccessExprSyntax.self) }
    var array: ArrayExprSyntax? { self.as(ArrayExprSyntax.self) }
    var dictionary: DictionaryExprSyntax? { self.as(DictionaryExprSyntax.self) }
}

extension StringLiteralExprSyntax {
    var string: String { "\(segments)" }
}
