import Foundation

/// A small element tree built with Foundation's XMLParser. Element and attribute
/// names are local names (no prefix), so transitional and strict OOXML both match.
final class XMLElement {
    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLElement] = []
    /// Text directly inside this element (concatenated character data).
    private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLElement? { children.first { $0.name == name } }
    func children(_ name: String) -> [XMLElement] { children.filter { $0.name == name } }
    /// The `val` attribute, which carries most values in WordprocessingML.
    var val: String? { attributes["val"] }

    fileprivate func append(_ child: XMLElement) { children.append(child) }
    fileprivate func append(text: String) { self.text += text }

    enum Failure: Error { case malformed(String) }

    static func parse(_ data: Data) throws -> XMLElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let line = parser.lineNumber
            let detail = parser.parserError?.localizedDescription ?? "parse failed"
            throw Failure.malformed("line \(line): \(detail)")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElement?
        private var stack: [XMLElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                attributes[String(key.split(separator: ":").last ?? Substring(key))] = value
            }
            let element = XMLElement(name: elementName, attributes: attributes)
            if let parent = stack.last { parent.append(element) } else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(text: string)
        }
    }
}
