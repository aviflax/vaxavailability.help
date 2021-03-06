(ns vax.help.background.email.verifications
  (:require [com.brunobonacci.mulog :as μ]
            [vax.help.config :as c :refer [env env! ss->ms]]
            [vax.help.i8n :as i8n]
            [next.jdbc :as jdbc]
            [next.jdbc.result-set :as rs]
            [next.jdbc.sql :as sql])
  (:import [com.wildbit.java.postmark Postmark]
           [com.wildbit.java.postmark.client.data.model.message Message]))

(defn build-config!
  "Throws if a required environment variable is missing or blank."
  []
  {:baseurl     (c/ensure-trailing-slash (env! "EXTERNAL_BASE_URL"))
   :db          {:dbtype       "postgresql"
                 :host         (env! "DB_HOST")
                 :port         (env! "DB_PORT")
                 :dbname       (env! "DB_NAME")
                 :user         (env! "DB_USERNAME")
                 :password     (env! "DB_PASSWORD")
                 ::comment     "This is (and must be) a valid next.jdbc dbspec."}
   :fetch-limit (Integer/parseInt (env! "FETCH_LIMIT"))
   :postmark    {:server-token (env! "POSTMARK_SERVER_TOKEN")}
   :sleep-ms      (ss->ms (env! "SUB_VERIFICATION_FREQUENCY_SECS"))  ; how long to pause between each "batch" i.e. query
   :err-sleep-ms  (ss->ms (env "SUB_VERIFICATION_ERR_SLEEP_SECS" "1"))})  ; how long to pause after an error

(defn- new-subs
  "Get subscriptions for which we have not yet sent verification emails."
  [dbconn cv]
  (sql/query dbconn
             ["SELECT id, email, language as lang, nonce, state, state_change_ts
               FROM subscription.with_current_state
               WHERE state='new'
               ORDER BY state_change_ts ASC
               LIMIT ?"
              (cv :fetch-limit)]
             {:builder-fn rs/as-unqualified-lower-maps}))

(defn verification-url
  [lang nonce base-url]
  (str base-url "subscription/verification?nonce=" nonce (when (not= lang "en")
                                                           (str "&lang=" (name lang)))))

(defn- body
  [t lang nonce base-url]
  (format
   (str (t "To verify your subscription to COVID-19 vaccination appointment updates, please open this link:")
        "\n\n%s\n\n"
        (t "If you did not request such notifications, you may ignore this email."))
   (verification-url lang nonce base-url)))

(defn sub->email
  [{:keys [email lang nonce] :as _sub} baseurl]
  (let [t           (i8n/translator lang)
        sender      "updates@vax.help"
        recipient   email
        subject     (t "Confirm your subscription to COVID-19 vaccination appointment updates")
        html-body   nil
        text-body   (body t lang nonce baseurl)]
    (Message. sender recipient subject html-body text-body)))

(defn send-verification-email
  "Returns nil upon success, otherwise throws. (Behavior inherited from Postmark lib.)
   TODO: return an ::anom/anomaly instead of throwing."
  [{:keys [id nonce] :as sub} pm-client cv]
  (try
    (let [msg           (sub->email sub (cv :baseurl))
          
          result        (do
                          (μ/log ::sending-email, :subscription/id id, :subscription/nonce nonce, :email/from (.getFrom msg), :email/to (.getTo msg), :email/subject (.getSubject msg))
                          (.deliverMessage pm-client msg))  ; returns an instance of MessageResponse

          error-code    (.getErrorCode result)
          success?      (zero? error-code)
          response-msg  (.getMessage result)
          msg-id        (.getMessageId result)]
      (μ/log ::postmark-response, :subscription/id id, :postmark/error-code error-code, :postmark/response-msg response-msg, :postmark/message-id msg-id)
      ; I’m pretty sure the lib throws on any kind of error, so this is probably unnecessary. That
      ; said, what else would we do? Not check the error code? That would be bizarre.
      (when-not success?
        (throw (ex-info (str "Postmark returned a non-zero error code: " error-code)
                        {:subscription/id       id
                         :postmark/error-code   error-code
                         :postmark/response-msg response-msg}))))
    (catch Exception e
      (μ/log ::postmark-error, :subscription/id id, :ex-class (.getSimpleName (class e)), :ex-msg (.getMessage e), :ex-data (ex-data e))
      {:error/category   :fault
       :error/message    (.getMessage e)
       :exception        e
       :subscription/id  id})))

(defn transition-sub-state
  [{id :id, :as _sub} dbconn]
  (let [new-state "pending-verification"]
    (μ/log ::transitioning-sub-state, :subscription/id id, :new-state new-state)
    (jdbc/execute! dbconn
                   ["insert into subscription.state_changes (subscription_id, state)
                     values (?, cast(? as subscription.state))"
                    id
                    new-state])))

(defn start
  [& _args]
  (let [config     (build-config!)
        cv         (c/get-getter config)
        pm-client  (Postmark/getApiClient (cv :postmark :server-token))
        dbconn     (jdbc/get-connection (cv :db))]
    (μ/log ::db-conn :connection :successful)
    (while true
      (try
        (when-let [new-subs (seq (new-subs dbconn cv))]
          (μ/log ::new-subs-found :count (count new-subs))
          (doseq [sub new-subs]
            (if-let [_send-error (send-verification-email sub pm-client cv)]
              (Thread/sleep (cv :err-sleep-ms))
              (transition-sub-state sub dbconn))))
        (catch Exception e
          (μ/log ::error, :ex-class (.getSimpleName (class e)), :ex-msg (.getMessage e), :ex-data (ex-data e))
          (Thread/sleep (cv :err-sleep-ms))))
      (Thread/sleep (cv :sleep-ms)))))
