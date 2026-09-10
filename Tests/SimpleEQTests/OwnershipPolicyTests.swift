import XCTest
@testable import SimpleEQ

/// セッション横断の所有権の状態遷移。ドライバを介さない純粋な判定部分だけを対象にする。
final class OwnershipPolicyTests: XCTestCase {

    // MARK: - 生値からの導出

    func testIsOwnedNeedsBothAProcessIDAndALiveLease() {
        XCTAssertFalse(OwnershipPolicy.isOwned(OwnershipSnapshot()))
        XCTAssertTrue(OwnershipPolicy.isOwned(OwnershipSnapshot(ownerProcessID: 501, ownershipLeaseRemainingSeconds: 3)))
        XCTAssertFalse(
            OwnershipPolicy.isOwned(OwnershipSnapshot(ownerProcessID: 501, ownershipLeaseRemainingSeconds: nil)),
            "pid が残っていてもリースを持っていなければ席は空いている"
        )
    }

    // 満了した席を数えると、生きている側が claim を打たなくなる。
    // ドライバの回収は所有権の Set と IO でしか走らないため、打たれなければ回収の契機ごと失われる。
    func testAnExpiredLeaseLeavesTheSeatEmptySoTheLivingSideStillClaims() {
        let expired = OwnershipSnapshot(ownerProcessID: 97009, ownershipLeaseRemainingSeconds: 0)

        XCTAssertFalse(OwnershipPolicy.isOwned(expired), "満了した所有者は席を占めていない")
        XCTAssertTrue(
            OwnershipPolicy.shouldClaimWhileUnowned(
                ownerPresent: OwnershipPolicy.isOwned(expired), isOnConsole: true, wasSelfOwner: false
            ),
            "席が空くので console 側が取りにいく"
        )
    }

    // 要求側も同じ構造。死んだ要求者を数えると、所有者が応える相手の居ない明け渡しへ進む。
    func testAnExpiredRequestLeaseStopsTheOwnerFromReleasingToNobody() {
        let expired = OwnershipSnapshot(requestProcessID: 777, requestLeaseRemainingSeconds: 0)

        XCTAssertFalse(OwnershipPolicy.isRequestedByOther(expired, selfProcessID: 501))
        XCTAssertFalse(
            OwnershipPolicy.shouldReleaseForRequest(
                isSelfOwner: true, requestPresent: OwnershipPolicy.isRequestedByOther(expired, selfProcessID: 501)
            )
        )
    }

    // 自分の席が満了しただけなら、降りるのではなく取り直す側へ進む。
    func testSelfOwnershipSurvivesItsOwnLeaseExpiringSoTheInstanceReclaims() {
        let expired = OwnershipSnapshot(ownerProcessID: 501, ownershipLeaseRemainingSeconds: 0)

        XCTAssertTrue(OwnershipPolicy.isSelfOwner(expired, selfProcessID: 501), "リース残量は自分かどうかを変えない")
        XCTAssertFalse(
            OwnershipPolicy.shouldSuspendForLackOfOwnership(
                isSelfOwner: true, ownerPresent: OwnershipPolicy.isOwned(expired)
            ),
            "自分の席が満了しただけで出力段を止めない"
        )
        XCTAssertTrue(
            OwnershipPolicy.shouldClaimWhileUnowned(
                ownerPresent: OwnershipPolicy.isOwned(expired), isOnConsole: false, wasSelfOwner: true
            ),
            "console を持たなくても直前の所有者として取り直す"
        )
    }

    func testIsSelfOwnerComparesOnlyProcessID() {
        let snapshot = OwnershipSnapshot(ownerProcessID: 501, ownerUID: 999)
        XCTAssertTrue(OwnershipPolicy.isSelfOwner(snapshot, selfProcessID: 501))
        XCTAssertFalse(OwnershipPolicy.isSelfOwner(snapshot, selfProcessID: 502))
    }

    func testIsRequestedNeedsBothAProcessIDAndALiveLease() {
        XCTAssertFalse(OwnershipPolicy.isRequestedByOther(OwnershipSnapshot(), selfProcessID: 501))
        XCTAssertTrue(
            OwnershipPolicy.isRequestedByOther(
                OwnershipSnapshot(requestProcessID: 777, requestLeaseRemainingSeconds: 3), selfProcessID: 501
            )
        )
        XCTAssertFalse(
            OwnershipPolicy.isRequestedByOther(
                OwnershipSnapshot(requestProcessID: 777, requestLeaseRemainingSeconds: nil), selfProcessID: 501
            ),
            "pid が残っていてもリースを持っていなければ要求は無い"
        )
    }

    // 満了した所有者を直接掴むと、自分の要求が残ったまま所有者になる。ここで自分自身へ明け渡すと、
    // 取得した直後に出力段を止め、可視性と復元の義務を降ろしてしまう。
    func testAnOwnersOwnStandingRequestIsNotSomeoneToHandOverTo() {
        let ownStanding = OwnershipSnapshot(
            ownerProcessID: 501, ownershipLeaseRemainingSeconds: 6,
            requestProcessID: 501, requestLeaseRemainingSeconds: 5
        )

        XCTAssertFalse(OwnershipPolicy.isRequestedByOther(ownStanding, selfProcessID: 501), "自分の要求は相手ではない")
        XCTAssertFalse(
            OwnershipPolicy.shouldReleaseForRequest(
                isSelfOwner: true,
                requestPresent: OwnershipPolicy.isRequestedByOther(ownStanding, selfProcessID: 501)
            ),
            "自分自身へ明け渡さない"
        )
        XCTAssertTrue(
            OwnershipPolicy.isRequestedByOther(ownStanding, selfProcessID: 502),
            "他者から見れば待っている相手として見える"
        )
    }

    // MARK: - 空いている間の取得

    // console を持つ側は空いていれば取りにいく。console は同時に 1 つなので先着争いにならない。
    // 持たない側は、直前に自分が所有していたとき (意図せず失ったとき) だけ取り直す。
    func testClaimsWhileUnownedForTheConsoleHolderOrThePreviousOwner() {
        XCTAssertTrue(OwnershipPolicy.shouldClaimWhileUnowned(ownerPresent: false, isOnConsole: true, wasSelfOwner: false))
        XCTAssertTrue(OwnershipPolicy.shouldClaimWhileUnowned(ownerPresent: false, isOnConsole: false, wasSelfOwner: true))
        XCTAssertFalse(
            OwnershipPolicy.shouldClaimWhileUnowned(ownerPresent: false, isOnConsole: false, wasSelfOwner: false),
            "console も持たず直前の所有者でもないなら取りにいかない"
        )
        for console in [true, false] {
            for was in [true, false] {
                XCTAssertFalse(
                    OwnershipPolicy.shouldClaimWhileUnowned(ownerPresent: true, isOnConsole: console, wasSelfOwner: was),
                    "所有者が居る間は取らない (console=\(console) was=\(was))"
                )
            }
        }
    }

    // 取り直しの権利を観測値で潰すと、claim が 1 回空振りしただけで console を持たない側が
    // 二度と取りにいけなくなる。空席のままなら次の周も打てること、他者が座れば諦めることを対で見る。
    func testTheRightToReclaimSurvivesAClaimThatDidNotLand() {
        // 席が空いた周: 観測上は自分の席ではないが、権利は残す。
        let afterFailedClaim = OwnershipPolicy.retainedSelfOwnership(
            isSelfOwner: false, ownerPresent: false, previous: true
        )
        XCTAssertTrue(afterFailedClaim)
        XCTAssertTrue(
            OwnershipPolicy.shouldClaimWhileUnowned(
                ownerPresent: false, isOnConsole: false, wasSelfOwner: afterFailedClaim
            ),
            "console を持たなくても次の周でもう一度打てる"
        )

        XCTAssertFalse(
            OwnershipPolicy.retainedSelfOwnership(isSelfOwner: false, ownerPresent: true, previous: true),
            "他者が座った時点で権利を落とす"
        )
        XCTAssertTrue(
            OwnershipPolicy.retainedSelfOwnership(isSelfOwner: true, ownerPresent: true, previous: false),
            "自分が座っていれば記憶は真"
        )
        XCTAssertFalse(
            OwnershipPolicy.retainedSelfOwnership(isSelfOwner: false, ownerPresent: false, previous: false),
            "空席でも直前が自分でなければ権利は無い"
        )
    }

    func testShouldRenewOwnershipOnlyWhileSelfOwner() {
        XCTAssertTrue(OwnershipPolicy.shouldRenewOwnership(isSelfOwner: true))
        XCTAssertFalse(OwnershipPolicy.shouldRenewOwnership(isSelfOwner: false))
    }

    func testShouldRenewRequestOnlyWhileRequestingAndNotYetOwner() {
        XCTAssertTrue(OwnershipPolicy.shouldRenewRequest(isRequestingOwnership: true, isSelfOwner: false))
        XCTAssertFalse(
            OwnershipPolicy.shouldRenewRequest(isRequestingOwnership: true, isSelfOwner: true),
            "所有者になった時点で要求は用済み"
        )
        XCTAssertFalse(OwnershipPolicy.shouldRenewRequest(isRequestingOwnership: false, isSelfOwner: false))
    }

    // MARK: - 明け渡し

    func testShouldReleaseForRequestOnlyWhileSelfOwnerAndRequestPresent() {
        XCTAssertTrue(OwnershipPolicy.shouldReleaseForRequest(isSelfOwner: true, requestPresent: true))
        XCTAssertFalse(OwnershipPolicy.shouldReleaseForRequest(isSelfOwner: true, requestPresent: false))
        XCTAssertFalse(OwnershipPolicy.shouldReleaseForRequest(isSelfOwner: false, requestPresent: true), "自分が所有者でなければ明け渡しようがない")
    }

    // MARK: - 出力段の停止/再開

    func testShouldSuspendForLackOfOwnershipOnlyWhenSomeoneElseOwns() {
        XCTAssertTrue(OwnershipPolicy.shouldSuspendForLackOfOwnership(isSelfOwner: false, ownerPresent: true))
        XCTAssertFalse(OwnershipPolicy.shouldSuspendForLackOfOwnership(isSelfOwner: false, ownerPresent: false), "所有者が不在なら止める理由が無い")
        XCTAssertFalse(OwnershipPolicy.shouldSuspendForLackOfOwnership(isSelfOwner: true, ownerPresent: true))
    }

    func testShouldResumeEngineOnlyForSelfOwnerAndOwnershipUnavailableCause() {
        XCTAssertTrue(OwnershipPolicy.shouldResumeEngine(isSelfOwner: true, processingState: .suspended(.ownershipUnavailable)))
        XCTAssertFalse(OwnershipPolicy.shouldResumeEngine(isSelfOwner: false, processingState: .suspended(.ownershipUnavailable)))
        XCTAssertFalse(
            OwnershipPolicy.shouldResumeEngine(isSelfOwner: true, processingState: .suspended(.routeUnavailable)),
            "所有権の取得は所有権喪失による停止だけを再開の対象にする"
        )
        XCTAssertFalse(OwnershipPolicy.shouldResumeEngine(isSelfOwner: true, processingState: .active))
    }

    // MARK: - 実体差し替えの検出

    func testDetectedReplacementRequiresAPreviousObservationToCompareAgainst() {
        XCTAssertFalse(OwnershipPolicy.detectedReplacement(previousInode: nil, currentInode: 42), "初回観測は比較対象が無い")
        XCTAssertFalse(OwnershipPolicy.detectedReplacement(previousInode: 42, currentInode: 42))
        XCTAssertTrue(OwnershipPolicy.detectedReplacement(previousInode: 42, currentInode: 43))
    }

    // MARK: - UI 世界へ押し出す同定

    // 満了した席の pid を押し出すと、誰も居ない席が「他のセッションが使用中」と読まれ、
    // 空席なら console を持たなくても掴めるはずの導線まで閉じる。
    func testAnExpiredSeatIsPublishedAsAbsentSoTheEmptySeatStaysReachable() {
        let expired = OwnershipSnapshot(ownerProcessID: 97009, ownerUID: 501, ownershipLeaseRemainingSeconds: 0)
        let identity = OwnershipPolicy.publishedOwnerIdentity(expired)

        XCTAssertEqual(identity.processID, 0)
        XCTAssertEqual(identity.uid, 0)
        XCTAssertTrue(
            OwnershipPolicy.allowsHandoverAction(ownerPresent: identity.processID != 0, isOnConsole: false),
            "空席は console を持たなくても掴める"
        )
    }

    func testALiveSeatIsPublishedAsItStands() {
        let live = OwnershipSnapshot(ownerProcessID: 97009, ownerUID: 501, ownershipLeaseRemainingSeconds: 3)
        let identity = OwnershipPolicy.publishedOwnerIdentity(live)

        XCTAssertEqual(identity.processID, 97009)
        XCTAssertEqual(identity.uid, 501)
    }

    // MARK: - 表示用テキスト

    func testOwnerDisplayTextShowsAbsenceWhenProcessIDIsZero() {
        XCTAssertEqual(OwnershipPolicy.ownerDisplayText(processID: 0, uid: 999), "なし")
    }

    func testOwnerDisplayTextIncludesBothProcessIDAndUID() {
        XCTAssertEqual(OwnershipPolicy.ownerDisplayText(processID: 501, uid: 20), "pid 501 / uid 20")
    }

    // MARK: - 直前の所有の記憶

    // 読めない窓 (ドライバの再準備・coreaudiod 再起動) こそが取り直しの対象なので、そこで忘れると復帰できない。
    func testPriorOwnershipIsRememberedThroughAWindowWhereTheStateCannotBeRead() {
        XCTAssertTrue(
            OwnershipPolicy.lastKnownSelfOwnership(observed: false, isSelfOwner: false, previous: true),
            "読めない間は直前の記憶を保つ"
        )
        XCTAssertFalse(
            OwnershipPolicy.lastKnownSelfOwnership(observed: false, isSelfOwner: false, previous: false),
            "所有していなかったなら読めなくても偽のまま"
        )
        XCTAssertFalse(
            OwnershipPolicy.lastKnownSelfOwnership(observed: true, isSelfOwner: false, previous: true),
            "読めたなら観測した値で置き換える"
        )
        XCTAssertTrue(OwnershipPolicy.lastKnownSelfOwnership(observed: true, isSelfOwner: true, previous: false))
    }

    // MARK: - 「こちらで使う」

    // 所有者が居ないときに要求を打つと、応える相手が居ないまま待ち続ける。
    func testHandoverClaimsDirectlyWhileNobodyOwns() {
        XCTAssertEqual(OwnershipPolicy.handoverOperation(ownerPresent: false), .claim)
        XCTAssertEqual(OwnershipPolicy.handoverOperation(ownerPresent: true), .request)
    }

    // MARK: - ドライバ操作の権限

    // 他セッションが所有している間は、その音声経路の足元でドライバを差し替えさせない。
    // 誰も所有していないときは通す。ここを塞ぐと初回インストールができなくなる。
    func testDriverOperationsAreDeniedOnlyWhileAnotherSessionOwnsThePath() {
        XCTAssertFalse(
            OwnershipPolicy.allowsDriverOperation(ownerPresent: true, isSelfOwner: false),
            "他セッションが所有している間は触らせない"
        )
        XCTAssertTrue(OwnershipPolicy.allowsDriverOperation(ownerPresent: true, isSelfOwner: true), "所有者本人は操作できる")
        XCTAssertTrue(
            OwnershipPolicy.allowsDriverOperation(ownerPresent: false, isSelfOwner: false),
            "所有者が不在なら誰でも操作できる (初回インストールが通る条件)"
        )
    }

    // 非 console セッションは描画も Diagnostics も止まるため、そこから見えている側の音を奪わせない。
    // 空いているものを取るのは妨げない (console 側でアプリが起動していない構成が成り立たなくなる)。
    func testTakingFromAnotherSessionNeedsTheConsoleButClaimingAnUnownedPathDoesNot() {
        XCTAssertFalse(OwnershipPolicy.allowsHandoverAction(ownerPresent: true, isOnConsole: false), "非 console から奪えない")
        XCTAssertTrue(OwnershipPolicy.allowsHandoverAction(ownerPresent: true, isOnConsole: true), "console からは奪える")
        XCTAssertTrue(OwnershipPolicy.allowsHandoverAction(ownerPresent: false, isOnConsole: false), "空いていれば非 console でも取れる")
        XCTAssertTrue(OwnershipPolicy.allowsHandoverAction(ownerPresent: false, isOnConsole: true))
    }
}
