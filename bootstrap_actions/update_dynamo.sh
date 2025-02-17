#!/bin/bash
(
    INSTANCE_ROLE=$(jq .instanceRole /mnt/var/lib/info/extraInstanceData.json)

    #only log on master to avoid duplication
    if [[ "$INSTANCE_ROLE" != '"MASTER"' ]]; then
      exit 0
    fi
    source /opt/emr/logging.sh

    function log_wrapper_message() {
        log_pdm_message "$${1}" "update_dynamo.sh" "$${PID}" "$${@:2}" "Running as: ,$USER"
    }

  log_wrapper_message "Start running update_dynamo.sh Shell"

  STEP_DETAILS_DIR=/mnt/var/lib/info/steps
  CORRELATION_ID_FILE=/opt/emr/correlation_id.txt
  S3_PREFIX_FILE=/opt/emr/s3_prefix.txt
  SNAPSHOT_TYPE_FILE=/opt/emr/snapshot_type.txt
  EXPORT_DATE_FILE=/opt/emr/export_date.txt
  DATE=$(date '+%Y-%m-%d')
  DATA_PRODUCT="PDM"
  CLUSTER_ID=$(jq '.jobFlowId' < /mnt/var/lib/info/job-flow.json)
  CLUSTER_ID="$${CLUSTER_ID//\"}"
  
  FAILED_STATUS="FAILED"
  COMPLETED_STATUS="COMPLETED"
  IN_PROGRESS_STATUS="IN_PROGRESS"
  CANCELLED_STATUS="CANCELLED"

  FINAL_STEP_NAME="create-views-tables"

  while [[ ! -f "$CORRELATION_ID_FILE" ]] && [[ ! -f "$S3_PREFIX_FILE" ]] && [[ ! -f "$SNAPSHOT_TYPE_FILE" ]] && [[ ! -f "$EXPORT_DATE_FILE" ]]
  do
    sleep 5
  done

  CORRELATION_ID=$(cat $CORRELATION_ID_FILE)
  S3_PREFIX=$(cat $S3_PREFIX_FILE)
  SNAPSHOT_TYPE=$(cat $SNAPSHOT_TYPE_FILE)
  EXPORT_DATE=$(cat $EXPORT_DATE_FILE)

  if [[ -z "$EXPORT_DATE" ]]; then
    log_wrapper_message "Export date from file was empty, so defaulting to today's date"
    EXPORT_DATE="$DATE"
  fi

  processed_files=()

  get_ttl() {
      TIME_NOW=$(($(date +'%s * 1000 + %-N / 1000000')))
      echo $((TIME_NOW + 604800000))
  }

  dynamo_update_item() {
    current_step="$1"
    status="$2"
    run_id="$3"

    ttl_value=$(get_ttl)

    log_wrapper_message "Updating DynamoDB with Correlation_Id: $CORRELATION_ID, DataProduct: $DATA_PRODUCT, Date: $EXPORT_DATE, Cluster_Id: $CLUSTER_ID, S3_Prefix_Analytical_DataSet: $S3_PREFIX, Snapshot_Type: $SNAPSHOT_TYPE, TimeToExist: $ttl_value, CurrentStep: $current_step, Status: $status, Run_Id: $run_id"

    update_expression="SET #d = :s, Cluster_Id = :v, S3_Prefix_Analytical_DataSet = :b, Snapshot_Type = :x, TimeToExist = :z"
    expression_values="\":s\": {\"S\":\"$EXPORT_DATE\"}, \":v\": {\"S\":\"$CLUSTER_ID\"}, \":b\": {\"S\":\"$S3_PREFIX\"}, \":x\": {\"S\":\"$SNAPSHOT_TYPE\"}, \":z\": {\"N\":\"$ttl_value\"}"
    expression_names="\"#d\":\"Date\""

    if [[ -n "$current_step" ]] && [[ "$current_step" != "NOT_SET" ]]; then
        update_expression="$update_expression, CurrentStep = :y"
        expression_values="$expression_values, \":y\": {\"S\":\"$current_step\"}"
    fi

    if [[ -n "$status" ]] && [[ "$status" != "NOT_SET" ]]; then
        update_expression="$update_expression, #a = :u"
        expression_values="$expression_values, \":u\": {\"S\":\"$status\"}"
        expression_names="$expression_names, \"#a\":\"Status\""
    fi

    if [[ -n "$run_id" ]] && [[ "$run_id" != "NOT_SET" ]]; then
        update_expression="$update_expression, Run_Id = :t"
        expression_values="$expression_values, \":t\": {\"N\":\"$run_id\"}"
    fi

    $(which aws) dynamodb update-item  --table-name "${dynamodb_table_name}" \
        --key "{\"Correlation_Id\":{\"S\":\"$CORRELATION_ID\"},\"DataProduct\":{\"S\":\"$DATA_PRODUCT\"}}" \
        --update-expression "$update_expression" \
        --expression-attribute-values "{$expression_values}" \
        --expression-attribute-names "{$expression_names}"
  }

  check_step_dir() {
    cd "$STEP_DETAILS_DIR" || exit
    #shellcheck disable=SC2231
    for i in $STEP_DETAILS_DIR/*.json; do # We want wordsplitting here
      #shellcheck disable=SC2076
      if [[ "$${processed_files[@]}" =~ "$${i}" ]]; then # We do not want a REGEX check here so it is ok
        continue
      fi
      state=$(jq -r '.state' "$i")
      while [[ "$state" != "$COMPLETED_STATUS" ]]; do
        step_script_name=$(jq -r '.args[0]' "$i")
        CURRENT_STEP=$(echo "$step_script_name" | sed 's:.*/::' | cut -f 1 -d '.')
        state=$(jq -r '.state' "$i")
        if [[ "$state" == "$FAILED_STATUS" ]] || [[ "$state" == "$CANCELLED_STATUS" ]]; then
          log_wrapper_message "Failed step. Step Name: $CURRENT_STEP, Step status: $state"
          dynamo_update_item "$CURRENT_STEP" "$FAILED_STATUS" "NOT_SET"
          exit 0
        fi
        if [[ "$CURRENT_STEP" == "$FINAL_STEP_NAME" ]] && [[ "$state" == "$COMPLETED_STATUS" ]]; then
          dynamo_update_item "$CURRENT_STEP" "$COMPLETED_STATUS" "NOT_SET"
          log_wrapper_message "All steps completed. Final step Name: $CURRENT_STEP, Step status: $state"
          exit 0
        fi
        if [[ "$PREVIOUS_STATE" != "$state" ]] && [[ "$PREVIOUS_STEP" != "$CURRENT_STEP" ]]; then
          dynamo_update_item "$CURRENT_STEP" "NOT_SET" "NOT_SET"
          log_wrapper_message "Successful step. Last step name: $PREVIOUS_STEP, Last step status: $PREVIOUS_STATE, Current step name: $CURRENT_STEP, Current step status: $state"
          processed_files+=( "$i" )
        else
          sleep 5
        fi
        PREVIOUS_STATE=$state
        PREVIOUS_STEP=$CURRENT_STEP
      done
    done
    sleep 5
    check_step_dir
  }

  #Check if row for this correlation ID already exists - in which case we need to increment the Run_Id
  #shellcheck disable=SC2086
  response=$(aws dynamodb get-item --table-name ${dynamodb_table_name} --key '{"Correlation_Id": {"S": "'$CORRELATION_ID'"}, "DataProduct": {"S": "'$DATA_PRODUCT'"}}')
  if [[ -z $response ]]; then
    dynamo_update_item "NOT_SET" "$IN_PROGRESS_STATUS" "1"
  else
    LAST_STATUS=$(echo "$response" | jq -r .'Item.Status.S')
    log_wrapper_message "Status from previous run $LAST_STATUS"
    if [[ "$LAST_STATUS" == "$FAILED_STATUS" ]]; then
      log_wrapper_message "Previous failed status found, creating step_to_start_from.txt"
      CURRENT_STEP=$(echo "$response" | jq -r .'Item.CurrentStep.S')
      echo "$CURRENT_STEP" >> /opt/emr/step_to_start_from.txt
    fi   

    CURRENT_RUN_ID=$(echo "$response" | jq -r .'Item.Run_Id.N')
    NEW_RUN_ID=$((CURRENT_RUN_ID+1))
    dynamo_update_item "NOT_SET" "$IN_PROGRESS_STATUS" "$NEW_RUN_ID"
  fi
  log_wrapper_message "Updating DynamoDB with CORRELATION_ID: $CORRELATION_ID and RUN_ID: $NEW_RUN_ID"

  #kick off loop to process all step files
  check_step_dir

) >> /var/log/pdm/update_dynamo_sh.log 2>&1
