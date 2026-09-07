use std::fmt;

#[derive(Debug)]
pub enum GenerationError {
    Json(serde_json::Error),
    Invalid(String),
}

impl GenerationError {
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }
}

impl fmt::Display for GenerationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(error) => write!(f, "{error}"),
            Self::Invalid(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for GenerationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            Self::Invalid(_) => None,
        }
    }
}

impl From<serde_json::Error> for GenerationError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
