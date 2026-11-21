//
//  TreeState.swift — serialize/restore an AUParameterTree as a named-preset blob.
//  Used by parameter-tree plug-ins (every Paradise FX) for SAVE / LOAD presets.
//  (Auto-persist with the host project is already handled by AUAudioUnit's
//  default fullState, which carries the parameter tree.)
//

import Foundation
import AudioToolbox

enum TreeState {
    /// Encode every parameter's value as JSON (address → value).
    static func data(_ tree: AUParameterTree?) -> Data {
        guard let tree = tree else { return Data() }
        var dict: [String: Float] = [:]
        for p in tree.allParameters { dict[String(p.address)] = p.value }
        return (try? JSONEncoder().encode(dict)) ?? Data()
    }

    /// Apply a previously-saved blob back onto the tree.
    static func apply(_ data: Data, to tree: AUParameterTree?) {
        guard let tree = tree,
              let dict = try? JSONDecoder().decode([String: Float].self, from: data) else { return }
        for (k, v) in dict {
            if let a = AUParameterAddress(k) { tree.parameter(withAddress: a)?.setValue(v, originator: nil) }
        }
    }
}
