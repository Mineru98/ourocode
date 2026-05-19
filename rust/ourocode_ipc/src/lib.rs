//! Rust-side IPC/RPC request decoding for replaceable ourocode helper workers.
//!
//! Elixir owns the source of truth, lifecycle, supervision, journal, and
//! transport behavior. This crate only validates newline-delimited JSON request
//! frames and converts them into typed command structures for external Rust
//! helper processes.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::error::Error;
use std::fmt;

pub const CURRENT_VERSION: u64 = 1;
pub const REQUEST_MESSAGE_TYPE: &str = "ipc.rpc.request";
pub const RESPONSE_MESSAGE_TYPE: &str = "ipc.rpc.response";

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CommandName {
    pub method: String,
    pub action: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RpcRequest {
    pub message_id: String,
    pub command: CommandName,
    pub params: Map<String, Value>,
    pub metadata: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RpcResponse {
    pub message_id: String,
    pub request_id: String,
    pub status: ResponseStatus,
    pub result: Map<String, Value>,
    pub error: Option<DispatchError>,
    pub metadata: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResponseStatus {
    Ok,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DispatchError {
    pub code: String,
    pub message: String,
    pub detail: Option<Map<String, Value>>,
}

pub type DispatchResult = Result<Map<String, Value>, DispatchError>;

pub trait CommandHandler: Send + Sync {
    fn handle(&self, request: &RpcRequest) -> DispatchResult;
}

impl<F> CommandHandler for F
where
    F: Fn(&RpcRequest) -> DispatchResult + Send + Sync,
{
    fn handle(&self, request: &RpcRequest) -> DispatchResult {
        self(request)
    }
}

#[derive(Default)]
pub struct CommandDispatcher {
    handlers: HashMap<CommandName, Box<dyn CommandHandler>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DecodeError {
    MalformedJson(String),
    EnvelopeNotObject,
    UnsupportedVersion(Value),
    InvalidMessageType(String),
    MissingField(&'static str),
    InvalidField { field: &'static str, value: Value },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::MalformedJson(message) => write!(f, "malformed JSON: {message}"),
            DecodeError::EnvelopeNotObject => write!(f, "IPC envelope must be a JSON object"),
            DecodeError::UnsupportedVersion(value) => {
                write!(f, "unsupported IPC envelope version: {value}")
            }
            DecodeError::InvalidMessageType(message_type) => {
                write!(f, "invalid IPC message type: {message_type}")
            }
            DecodeError::MissingField(field) => write!(f, "missing required field: {field}"),
            DecodeError::InvalidField { field, value } => {
                write!(f, "invalid field {field}: {value}")
            }
        }
    }
}

impl Error for DecodeError {}

#[derive(Debug, Clone, PartialEq)]
pub enum DispatchSetupError {
    InvalidCommandField { field: &'static str, value: String },
    DuplicateHandler(CommandName),
}

impl fmt::Display for DispatchSetupError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DispatchSetupError::InvalidCommandField { field, value } => {
                write!(f, "invalid command {field}: {value}")
            }
            DispatchSetupError::DuplicateHandler(command) => {
                write!(
                    f,
                    "duplicate handler for command {}:{}",
                    command.method, command.action
                )
            }
        }
    }
}

impl Error for DispatchSetupError {}

impl CommandName {
    pub fn new(
        method: impl Into<String>,
        action: impl Into<String>,
    ) -> Result<Self, DispatchSetupError> {
        let method = trim_non_blank(method.into(), "method")?;
        let action = trim_non_blank(action.into(), "action")?;

        Ok(Self { method, action })
    }
}

impl DispatchError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            detail: None,
        }
    }

    pub fn with_detail(
        code: impl Into<String>,
        message: impl Into<String>,
        detail: Map<String, Value>,
    ) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            detail: Some(detail),
        }
    }

    pub fn to_value(&self) -> Value {
        let mut error = Map::new();
        error.insert("code".to_owned(), Value::String(self.code.clone()));
        error.insert("message".to_owned(), Value::String(self.message.clone()));

        if let Some(detail) = &self.detail {
            error.insert("detail".to_owned(), Value::Object(detail.clone()));
        }

        Value::Object(error)
    }
}

impl RpcResponse {
    pub fn ok(
        request_id: impl Into<String>,
        result: Map<String, Value>,
        metadata: Map<String, Value>,
    ) -> Self {
        let request_id = request_id.into();

        Self {
            message_id: response_message_id(&request_id),
            request_id,
            status: ResponseStatus::Ok,
            result,
            error: None,
            metadata,
        }
    }

    pub fn execution_error(
        request_id: impl Into<String>,
        error: DispatchError,
        metadata: Map<String, Value>,
    ) -> Self {
        let request_id = request_id.into();

        Self {
            message_id: response_message_id(&request_id),
            request_id,
            status: ResponseStatus::Error,
            result: Map::new(),
            error: Some(error),
            metadata,
        }
    }

    pub fn ok_for_request(
        request: &RpcRequest,
        result: Map<String, Value>,
        metadata: Map<String, Value>,
    ) -> Self {
        Self::ok(request.message_id.clone(), result, metadata)
    }

    pub fn error_for_request(
        request: &RpcRequest,
        error: DispatchError,
        metadata: Map<String, Value>,
    ) -> Self {
        Self::execution_error(request.message_id.clone(), error, metadata)
    }

    pub fn to_envelope_value(&self) -> Value {
        let mut payload = Map::new();
        payload.insert(
            "request_id".to_owned(),
            Value::String(self.request_id.clone()),
        );

        match self.status {
            ResponseStatus::Ok => {
                payload.insert("status".to_owned(), Value::String("ok".to_owned()));
                payload.insert("result".to_owned(), Value::Object(self.result.clone()));
            }
            ResponseStatus::Error => {
                payload.insert("status".to_owned(), Value::String("error".to_owned()));
                payload.insert(
                    "error".to_owned(),
                    self.error
                        .as_ref()
                        .map(DispatchError::to_value)
                        .unwrap_or_else(|| {
                            DispatchError::new("worker_failed", "helper command failed").to_value()
                        }),
                );
            }
        }

        let mut envelope = Map::new();
        envelope.insert("version".to_owned(), Value::Number(CURRENT_VERSION.into()));
        envelope.insert(
            "message_id".to_owned(),
            Value::String(self.message_id.clone()),
        );
        envelope.insert(
            "message_type".to_owned(),
            Value::String(RESPONSE_MESSAGE_TYPE.to_owned()),
        );
        envelope.insert("payload".to_owned(), Value::Object(payload));
        envelope.insert("metadata".to_owned(), Value::Object(self.metadata.clone()));

        Value::Object(envelope)
    }

    pub fn encode(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&self.to_envelope_value())
    }

    pub fn encode_line(&self) -> Result<String, serde_json::Error> {
        self.encode().map(|encoded| encoded + "\n")
    }
}

pub fn encode_success_response_line(
    request_id: impl Into<String>,
    result: Map<String, Value>,
    metadata: Map<String, Value>,
) -> Result<String, serde_json::Error> {
    RpcResponse::ok(request_id, result, metadata).encode_line()
}

pub fn encode_execution_error_response_line(
    request_id: impl Into<String>,
    error: DispatchError,
    metadata: Map<String, Value>,
) -> Result<String, serde_json::Error> {
    RpcResponse::execution_error(request_id, error, metadata).encode_line()
}

impl CommandDispatcher {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register<H>(
        &mut self,
        method: impl Into<String>,
        action: impl Into<String>,
        handler: H,
    ) -> Result<(), DispatchSetupError>
    where
        H: CommandHandler + 'static,
    {
        let command = CommandName::new(method, action)?;

        if self.handlers.contains_key(&command) {
            return Err(DispatchSetupError::DuplicateHandler(command));
        }

        self.handlers.insert(command, Box::new(handler));
        Ok(())
    }

    pub fn dispatch(&self, request: &RpcRequest) -> RpcResponse {
        let metadata = request.metadata.clone();

        match self.handlers.get(&request.command) {
            Some(handler) => match handler.handle(request) {
                Ok(result) => RpcResponse::ok_for_request(request, result, metadata),
                Err(error) => RpcResponse::error_for_request(request, error, metadata),
            },
            None => {
                RpcResponse::error_for_request(request, unknown_command_error(request), metadata)
            }
        }
    }
}

pub fn decode_request_line(line: &str) -> Result<RpcRequest, DecodeError> {
    let trimmed = line.trim_end_matches(['\n', '\r']);
    decode_request(trimmed)
}

pub fn decode_request(frame: &str) -> Result<RpcRequest, DecodeError> {
    let value: Value = serde_json::from_str(frame)
        .map_err(|error| DecodeError::MalformedJson(error.to_string()))?;
    decode_request_value(value)
}

pub fn decode_request_value(value: Value) -> Result<RpcRequest, DecodeError> {
    let mut envelope = into_object(value, "envelope")?;

    let version = take_required(&mut envelope, "version")?;
    if version.as_u64() != Some(CURRENT_VERSION) {
        return Err(DecodeError::UnsupportedVersion(version));
    }

    let message_id = required_non_blank_string(&mut envelope, "message_id")?;
    let message_type = required_non_blank_string(&mut envelope, "message_type")?;
    if message_type != REQUEST_MESSAGE_TYPE {
        return Err(DecodeError::InvalidMessageType(message_type));
    }

    let mut payload = optional_object(&mut envelope, "payload")?;
    let metadata = optional_object(&mut envelope, "metadata")?;

    let method = required_non_blank_string(&mut payload, "method")?;
    let action = required_non_blank_string(&mut payload, "action")?;
    let params = optional_object(&mut payload, "params")?;

    Ok(RpcRequest {
        message_id,
        command: CommandName { method, action },
        params,
        metadata,
    })
}

pub fn dispatch_decoded_request(
    dispatcher: &CommandDispatcher,
    request: &RpcRequest,
) -> RpcResponse {
    dispatcher.dispatch(request)
}

pub fn dispatch_decoded_request_line(
    dispatcher: &CommandDispatcher,
    line: &str,
) -> Result<String, DecodeError> {
    let request = decode_request_line(line)?;
    let response = dispatch_decoded_request(dispatcher, &request);
    Ok(response
        .encode_line()
        .expect("response envelope contains only JSON values"))
}

fn take_required(
    object: &mut Map<String, Value>,
    field: &'static str,
) -> Result<Value, DecodeError> {
    object.remove(field).ok_or(DecodeError::MissingField(field))
}

fn required_non_blank_string(
    object: &mut Map<String, Value>,
    field: &'static str,
) -> Result<String, DecodeError> {
    match take_required(object, field)? {
        Value::String(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Err(DecodeError::InvalidField {
                    field,
                    value: Value::String(value),
                })
            } else {
                Ok(trimmed.to_owned())
            }
        }
        value => Err(DecodeError::InvalidField { field, value }),
    }
}

fn optional_object(
    object: &mut Map<String, Value>,
    field: &'static str,
) -> Result<Map<String, Value>, DecodeError> {
    match object.remove(field) {
        Some(value) => into_object(value, field),
        None => Ok(Map::new()),
    }
}

fn into_object(value: Value, field: &'static str) -> Result<Map<String, Value>, DecodeError> {
    match value {
        Value::Object(object) => Ok(object),
        value if field == "envelope" => {
            let _ = value;
            Err(DecodeError::EnvelopeNotObject)
        }
        value => Err(DecodeError::InvalidField { field, value }),
    }
}

fn trim_non_blank(value: String, field: &'static str) -> Result<String, DispatchSetupError> {
    let trimmed = value.trim();

    if trimmed.is_empty() {
        Err(DispatchSetupError::InvalidCommandField { field, value })
    } else {
        Ok(trimmed.to_owned())
    }
}

fn response_message_id(request_id: &str) -> String {
    format!("res-{request_id}")
}

fn unknown_command_error(request: &RpcRequest) -> DispatchError {
    let mut detail = Map::new();
    detail.insert(
        "method".to_owned(),
        Value::String(request.command.method.clone()),
    );
    detail.insert(
        "action".to_owned(),
        Value::String(request.command.action.clone()),
    );

    DispatchError::with_detail(
        "unknown_command",
        "no Rust helper handler is registered for this command",
        detail,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn valid_frame() -> String {
        r#"{
          "version": 1,
          "message_id": " req-1 ",
          "message_type": "ipc.rpc.request",
          "payload": {
            "method": " helper.scan ",
            "action": " run ",
            "params": {"path": "lib", "limit": 10}
          },
          "metadata": {"rust_worker": "scan-helper"}
        }"#
        .to_owned()
    }

    fn valid_request() -> RpcRequest {
        decode_request(&valid_frame()).expect("valid request")
    }

    #[test]
    fn decodes_valid_request_into_typed_command() {
        let request = decode_request(&valid_frame()).expect("valid request");

        assert_eq!(request.message_id, "req-1");
        assert_eq!(
            request.command,
            CommandName {
                method: "helper.scan".to_owned(),
                action: "run".to_owned()
            }
        );
        assert_eq!(request.params["path"], Value::String("lib".to_owned()));
        assert_eq!(request.params["limit"], Value::Number(10.into()));
        assert_eq!(
            request.metadata["rust_worker"],
            Value::String("scan-helper".to_owned())
        );
    }

    #[test]
    fn decodes_newline_delimited_frame() {
        let request = decode_request_line(&(valid_frame() + "\r\n")).expect("valid request line");

        assert_eq!(request.message_id, "req-1");
        assert_eq!(request.command.method, "helper.scan");
    }

    #[test]
    fn defaults_missing_optional_maps() {
        let frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"method": "helper.scan", "action": "run"}
        }"#;

        let request = decode_request(frame).expect("valid request");

        assert!(request.params.is_empty());
        assert!(request.metadata.is_empty());
    }

    #[test]
    fn rejects_malformed_json() {
        assert!(matches!(
            decode_request("{malformed json"),
            Err(DecodeError::MalformedJson(_))
        ));
    }

    #[test]
    fn rejects_non_object_envelope() {
        assert_eq!(decode_request("[]"), Err(DecodeError::EnvelopeNotObject));
    }

    #[test]
    fn rejects_unsupported_version() {
        let frame = r#"{
          "version": 2,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"method": "helper.scan", "action": "run"}
        }"#;

        assert_eq!(
            decode_request(frame),
            Err(DecodeError::UnsupportedVersion(Value::Number(2.into())))
        );
    }

    #[test]
    fn rejects_wrong_message_type() {
        let frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.response",
          "payload": {"method": "helper.scan", "action": "run"}
        }"#;

        assert_eq!(
            decode_request(frame),
            Err(DecodeError::InvalidMessageType(
                "ipc.rpc.response".to_owned()
            ))
        );
    }

    #[test]
    fn rejects_missing_required_payload_field() {
        let frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"action": "run"}
        }"#;

        assert_eq!(
            decode_request(frame),
            Err(DecodeError::MissingField("method"))
        );
    }

    #[test]
    fn rejects_blank_strings_after_trimming() {
        let frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"method": " ", "action": "run"}
        }"#;

        assert_eq!(
            decode_request(frame),
            Err(DecodeError::InvalidField {
                field: "method",
                value: Value::String(" ".to_owned())
            })
        );
    }

    #[test]
    fn rejects_non_map_params_and_metadata() {
        let params_frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"method": "helper.scan", "action": "run", "params": []}
        }"#;
        let metadata_frame = r#"{
          "version": 1,
          "message_id": "req-1",
          "message_type": "ipc.rpc.request",
          "payload": {"method": "helper.scan", "action": "run"},
          "metadata": []
        }"#;

        assert_eq!(
            decode_request(params_frame),
            Err(DecodeError::InvalidField {
                field: "params",
                value: Value::Array(vec![])
            })
        );
        assert_eq!(
            decode_request(metadata_frame),
            Err(DecodeError::InvalidField {
                field: "metadata",
                value: Value::Array(vec![])
            })
        );
    }

    #[test]
    fn registers_handlers_and_dispatches_decoded_requests() {
        let mut dispatcher = CommandDispatcher::new();
        dispatcher
            .register(" helper.scan ", " run ", |request: &RpcRequest| {
                let mut result = Map::new();
                result.insert("accepted".to_owned(), Value::Bool(true));
                result.insert(
                    "path".to_owned(),
                    request.params.get("path").cloned().unwrap_or(Value::Null),
                );
                Ok(result)
            })
            .expect("handler registration");

        let request = valid_request();
        let response = dispatch_decoded_request(&dispatcher, &request);

        assert_eq!(response.message_id, "res-req-1");
        assert_eq!(response.request_id, "req-1");
        assert_eq!(response.status, ResponseStatus::Ok);
        assert_eq!(response.result["accepted"], Value::Bool(true));
        assert_eq!(response.result["path"], Value::String("lib".to_owned()));
        assert_eq!(
            response.metadata["rust_worker"],
            Value::String("scan-helper".to_owned())
        );
    }

    #[test]
    fn encodes_successful_dispatch_as_elixir_response_envelope() {
        let mut dispatcher = CommandDispatcher::new();
        dispatcher
            .register("helper.scan", "run", |_request: &RpcRequest| {
                let mut result = Map::new();
                result.insert("worker".to_owned(), Value::String("rust-scan".to_owned()));
                Ok(result)
            })
            .expect("handler registration");

        let response_line =
            dispatch_decoded_request_line(&dispatcher, &(valid_frame() + "\n")).expect("response");
        let decoded: Value = serde_json::from_str(response_line.trim_end()).expect("json response");

        assert_eq!(decoded["version"], json!(1));
        assert_eq!(decoded["message_id"], json!("res-req-1"));
        assert_eq!(decoded["message_type"], json!(RESPONSE_MESSAGE_TYPE));
        assert_eq!(decoded["payload"]["request_id"], json!("req-1"));
        assert_eq!(decoded["payload"]["status"], json!("ok"));
        assert_eq!(decoded["payload"]["result"]["worker"], json!("rust-scan"));
        assert_eq!(decoded["metadata"]["rust_worker"], json!("scan-helper"));
    }

    #[test]
    fn encodes_success_response_line_for_helper_results() {
        let mut result = Map::new();
        result.insert("accepted".to_owned(), Value::Bool(true));
        result.insert("worker".to_owned(), Value::String("rust-parser".to_owned()));

        let mut metadata = Map::new();
        metadata.insert(
            "rust_worker".to_owned(),
            Value::String("rust-parser".to_owned()),
        );

        let response_line =
            encode_success_response_line("req-success-1", result, metadata).expect("response");

        assert!(response_line.ends_with('\n'));

        let decoded: Value = serde_json::from_str(response_line.trim_end()).expect("json response");
        assert_eq!(decoded["version"], json!(1));
        assert_eq!(decoded["message_id"], json!("res-req-success-1"));
        assert_eq!(decoded["message_type"], json!(RESPONSE_MESSAGE_TYPE));
        assert_eq!(decoded["payload"]["request_id"], json!("req-success-1"));
        assert_eq!(decoded["payload"]["status"], json!("ok"));
        assert_eq!(decoded["payload"]["result"]["accepted"], json!(true));
        assert_eq!(decoded["payload"]["result"]["worker"], json!("rust-parser"));
        assert!(decoded["payload"].get("error").is_none());
        assert_eq!(decoded["metadata"]["rust_worker"], json!("rust-parser"));
    }

    #[test]
    fn dispatches_handler_failures_as_structured_error_responses() {
        let mut dispatcher = CommandDispatcher::new();
        dispatcher
            .register("helper.scan", "run", |_request: &RpcRequest| {
                let mut detail = Map::new();
                detail.insert("exit_status".to_owned(), Value::Number(3.into()));
                Err(DispatchError::with_detail(
                    "worker_failed",
                    "helper command failed",
                    detail,
                ))
            })
            .expect("handler registration");

        let response = dispatcher.dispatch(&valid_request());

        assert_eq!(response.status, ResponseStatus::Error);
        assert_eq!(
            response.error,
            Some(DispatchError::with_detail(
                "worker_failed",
                "helper command failed",
                {
                    let mut detail = Map::new();
                    detail.insert("exit_status".to_owned(), Value::Number(3.into()));
                    detail
                },
            ))
        );

        let encoded: Value = serde_json::from_str(&response.encode().expect("encoded response"))
            .expect("json response");
        assert_eq!(encoded["payload"]["status"], json!("error"));
        assert_eq!(encoded["payload"]["error"]["code"], json!("worker_failed"));
        assert_eq!(
            encoded["payload"]["error"]["detail"]["exit_status"],
            json!(3)
        );
    }

    #[test]
    fn encodes_execution_error_response_line_with_structured_detail() {
        let mut detail = Map::new();
        detail.insert("exit_status".to_owned(), Value::Number(127.into()));
        detail.insert(
            "stderr_tail".to_owned(),
            Value::String("command not found".to_owned()),
        );

        let mut metadata = Map::new();
        metadata.insert(
            "rust_worker".to_owned(),
            Value::String("launcher".to_owned()),
        );

        let response_line = encode_execution_error_response_line(
            "req-error-1",
            DispatchError::with_detail("worker_exit", "helper process exited", detail),
            metadata,
        )
        .expect("response");

        assert!(response_line.ends_with('\n'));

        let decoded: Value = serde_json::from_str(response_line.trim_end()).expect("json response");
        assert_eq!(decoded["version"], json!(1));
        assert_eq!(decoded["message_id"], json!("res-req-error-1"));
        assert_eq!(decoded["message_type"], json!(RESPONSE_MESSAGE_TYPE));
        assert_eq!(decoded["payload"]["request_id"], json!("req-error-1"));
        assert_eq!(decoded["payload"]["status"], json!("error"));
        assert!(decoded["payload"].get("result").is_none());
        assert_eq!(decoded["payload"]["error"]["code"], json!("worker_exit"));
        assert_eq!(
            decoded["payload"]["error"]["message"],
            json!("helper process exited")
        );
        assert_eq!(
            decoded["payload"]["error"]["detail"]["exit_status"],
            json!(127)
        );
        assert_eq!(
            decoded["payload"]["error"]["detail"]["stderr_tail"],
            json!("command not found")
        );
        assert_eq!(decoded["metadata"]["rust_worker"], json!("launcher"));
    }

    #[test]
    fn unknown_commands_return_structured_error_without_running_a_handler() {
        let dispatcher = CommandDispatcher::new();
        let response = dispatcher.dispatch(&valid_request());

        assert_eq!(response.status, ResponseStatus::Error);

        let encoded: Value = serde_json::from_str(&response.encode().expect("encoded response"))
            .expect("json response");
        assert_eq!(encoded["payload"]["request_id"], json!("req-1"));
        assert_eq!(
            encoded["payload"]["error"]["code"],
            json!("unknown_command")
        );
        assert_eq!(
            encoded["payload"]["error"]["detail"]["method"],
            json!("helper.scan")
        );
        assert_eq!(
            encoded["payload"]["error"]["detail"]["action"],
            json!("run")
        );
    }

    #[test]
    fn rejects_duplicate_or_blank_handler_registration() {
        let mut dispatcher = CommandDispatcher::new();
        dispatcher
            .register("helper.scan", "run", |_request: &RpcRequest| Ok(Map::new()))
            .expect("handler registration");

        assert!(matches!(
            dispatcher.register("helper.scan", "run", |_request: &RpcRequest| Ok(Map::new())),
            Err(DispatchSetupError::DuplicateHandler(CommandName { method, action }))
                if method == "helper.scan" && action == "run"
        ));

        assert!(matches!(
            dispatcher.register(" ", "run", |_request: &RpcRequest| Ok(Map::new())),
            Err(DispatchSetupError::InvalidCommandField {
                field: "method",
                ..
            })
        ));
    }
}
