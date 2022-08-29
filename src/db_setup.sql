DROP TABLE IF EXISTS kisa_text_data;

CREATE TABLE kisa_text_data(
  id INTEGER PRIMARY KEY,
  data TEXT
);

INSERT INTO kisa_text_data (data) VALUES (
 json('
  {
      "lines": [
          {
              "number": 1,
              "segments": [
                  {
                      "c": "Hello",
                      "style": {
                          "fg": "default",
                          "bg": "default",
                          "fs": 0
                      }
                  }
              ]
          },
          {
              "number": 2,
              "segments": [
                  {
                      "c": "w",
                      "style": {
                          "fg": "red",
                          "bg": "default",
                          "fs": 1
                      }
                  },
                  {
                      "c": "o",
                      "style": {
                          "fg": "green",
                          "bg": "default",
                          "fs": 3
                      }
                  },
                  {
                      "c": "rld!",
                      "style": {
                          "fg": { "r": 255, "g": 0, "b": 0 },
                          "bg": "default",
                          "fs": 20
                      }
                  }
              ]
          },
          {
              "number": 3,
              "segments": [
                  {
                      "c": "Hello"
                  }
              ]
          }
      ]
  }
')
);
