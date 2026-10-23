import QuestCitadelAPI

/// The writes' outputs share one shape: 200, or a documented refusal carrying the server's `ErrorBody`.
private func refused(_ status: Int, _ body: Schemas.ErrorBody?) -> ServerAnswer {
    ServerAnswer(status: status, code: body?.code ?? "", message: body?.message ?? "")
}

extension Operations.MoveIssue.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.SetIssueEpic.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.TransitionIssue.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.SetIssueSprint.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.EstimateIssue.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.DecideApproval.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.CreateIssue.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

extension Operations.SetWipLimit.Output: ServerOutput {
    var refusal: ServerAnswer? {
        switch self {
        case .ok: nil
        case .badRequest(let r): refused(400, try? r.body.json)
        case .unauthorized(let r): refused(401, try? r.body.json)
        case .forbidden(let r): refused(403, try? r.body.json)
        case .notFound(let r): refused(404, try? r.body.json)
        case .conflict(let r): refused(409, try? r.body.json)
        case .tooManyRequests(let r): refused(429, try? r.body.json)
        case .internalServerError(let r): refused(500, try? r.body.json)
        case .undocumented(let status, _): refused(status, nil)
        }
    }
}

