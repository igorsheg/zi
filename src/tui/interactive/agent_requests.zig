const request_mod = @import("../../coding_agent/request.zig");
const oauth_mod = @import("../../coding_agent/auth/oauth.zig");

pub fn processWithBuffer(self: anytype, comptime AgentRequest: type, submitExtensionAsyncFromRunner: anytype) bool {
    var buf: [16]AgentRequest = undefined;
    while (true) {
        const n = self.request_queue.drainInto(&buf);
        if (n == 0) return true;

        var idle_processed = false;
        var prompt_processed = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var req = &buf[i];
            switch (req.*) {
                .prompt => |p| {
                    prompt_processed = true;
                    const outcome = self.runtime_host.runUserContent(p.content) catch |err| {
                        const err_msg = self.msg_allocator.dupe(u8, @errorName(err)) catch null;
                        _ = self.publishLifecycleUiEvent(.{ .prompt_worker_finished = .{
                            .outcome = .assistant_error,
                            .internal_error = err_msg,
                        } });
                        req.deinit(self.msg_allocator);
                        continue;
                    };
                    self.publishPendingExtensionUi();
                    _ = self.publishLifecycleUiEvent(.{ .prompt_worker_finished = .{ .outcome = outcome } });
                },
                .resume_session => |r| {
                    idle_processed = true;
                    self.handleResumeSession(r.path, r.restore_session_model);
                },
                .fork_session => |f| {
                    idle_processed = true;
                    self.handleForkSession(f.entry_id);
                },
                .new_session => {
                    idle_processed = true;
                    self.handleNewSession();
                },
                .set_model => |s| {
                    idle_processed = true;
                    self.handleSetModel(s.model);
                },
                .set_model_by_pattern => |s| {
                    idle_processed = true;
                    self.handleSetModelPattern(s.pattern);
                },
                .set_thinking_level => |s| {
                    idle_processed = true;
                    self.handleSetThinkingLevel(s.level);
                },
                .refresh_status_snapshot => {
                    idle_processed = true;
                    self.publishStatusSnapshot();
                },
                .compact => |c| {
                    idle_processed = true;
                    self.handleManualCompactRequest(c.custom_instructions);
                },
                .extension_command => |ec| {
                    idle_processed = true;
                    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
                        runner.async_dispatcher = submitExtensionAsyncFromRunner(self);
                    }
                    self.runtime_host.dispatchExtensionCommand(ec.name, ec.args) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    self.publishPendingExtensionUi();
                },
                .extension_keybinding => |ek| {
                    idle_processed = true;
                    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
                        runner.async_dispatcher = submitExtensionAsyncFromRunner(self);
                    }
                    self.runtime_host.dispatchExtensionKeybinding(ek.id) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    self.publishPendingExtensionUi();
                },
                .extension_surface_input => |input| {
                    idle_processed = true;
                    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
                        runner.async_dispatcher = submitExtensionAsyncFromRunner(self);
                    }
                    self.runtime_host.dispatchExtensionSurfaceInput(input) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    self.publishPendingExtensionUi();
                },
                .extension_job_event => |event| {
                    idle_processed = true;
                    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
                        runner.async_dispatcher = submitExtensionAsyncFromRunner(self);
                    }
                    self.runtime_host.dispatchExtensionJobEvent(event) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    self.publishPendingExtensionUi();
                },
                .extension_oauth_login => |oauth| {
                    idle_processed = true;
                    const result: request_mod.ExtensionOAuthLoginResponse.Result = self.runtime_host.dispatchExtensionOAuthLogin(oauth.provider_id, oauth.callbacks) catch |err| blk: {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch break :blk .unsupported;
                        break :blk .{ .err = msg };
                    };
                    oauth.response.finish(result);
                },
                .extension_oauth_refresh => |oauth| {
                    idle_processed = true;
                    const exchange: oauth_mod.ExchangeResult = self.runtime_host.dispatchExtensionOAuthRefresh(oauth.provider_id, oauth.credential, oauth.result_allocator) catch |err| .{ .err = @errorName(err) };
                    const result: request_mod.ExtensionOAuthRefreshResponse.Result = switch (exchange) {
                        .success => |cred| .{ .success = cred },
                        .err => |msg| .{ .err = msg },
                    };
                    oauth.response.finish(result);
                },
                .extension_async_result => |async_result| {
                    idle_processed = true;
                    self.runtime_host.deliverExtensionAsyncResult(async_result.id, async_result.result) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    req.* = .{ .refresh_status_snapshot = {} };
                    self.publishPendingExtensionUi();
                },
                .tool_expanded_changed => |event| {
                    idle_processed = true;
                    if (self.runtime_host.currentSession().extensionRunner()) |runner| {
                        runner.async_dispatcher = submitExtensionAsyncFromRunner(self);
                    }
                    self.runtime_host.dispatchToolExpandedChanged(event.tool_name, event.tool_call_id, event.expanded) catch |err| {
                        const msg = self.msg_allocator.dupe(u8, @errorName(err)) catch continue;
                        _ = self.publishLifecycleUiEvent(.{ .error_message = .{ .message = msg } });
                    };
                    self.publishPendingExtensionUi();
                },
                .shutdown => {
                    req.deinit(self.msg_allocator);
                    self.discardAgentRequests(buf[i + 1 .. n]);
                    self.discardQueuedAgentRequests();
                    return false;
                },
            }
            req.deinit(self.msg_allocator);
        }

        if (idle_processed) {
            self.publishPendingExtensionUi();
        }
        if (idle_processed and !prompt_processed) {
            _ = self.publishLifecycleUiEvent(.{ .request_worker_finished = {} });
        }
    }
}
