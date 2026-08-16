/// ハンドル表示を出したままにするかの判定。
enum HandleRevealPolicy {
    static func staysRevealed(pointerButtonDown: Bool, pointerInsideCanvas: Bool) -> Bool {
        pointerButtonDown || pointerInsideCanvas
    }
}
