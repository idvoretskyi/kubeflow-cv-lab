NAMESPACE ?= kubeflow
JOB_NAME  ?= pytorch-mnist-gpu
MANIFEST  ?= pytorch-mnist-gpu.yaml
CONTEXT   ?= $(shell kubectl config current-context)

.PHONY: apply wait status logs clean

## Submit the TrainJob to the cluster.
apply:
	kubectl apply -f $(MANIFEST) --context $(CONTEXT)

## Wait for the TrainJob to complete (polls every 10 s, up to 10 min).
wait:
	@echo "Waiting for TrainJob $(JOB_NAME) to complete..."
	@for i in $$(seq 1 60); do \
	  cond=$$(kubectl get trainjob $(JOB_NAME) -n $(NAMESPACE) --context $(CONTEXT) \
	    -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null); \
	  phase=$$(kubectl get pod -l trainer.kubeflow.org/trainjob-name=$(JOB_NAME) \
	    -n $(NAMESPACE) --context $(CONTEXT) \
	    -o jsonpath='{.items[0].status.phase}' 2>/dev/null); \
	  echo "[$$i/60] job=$$cond  pod=$$phase"; \
	  case "$$cond" in JobComplete|JobFailed) break ;; esac; \
	  sleep 10; \
	done

## Show final TrainJob and pod status.
status:
	kubectl get trainjob $(JOB_NAME) -n $(NAMESPACE) --context $(CONTEXT) \
	  -o jsonpath='phase={.status.conditions[-1].type}{"\n"}'

## Stream logs from the trainer pod.
logs:
	kubectl logs -l trainer.kubeflow.org/trainjob-name=$(JOB_NAME) \
	  -n $(NAMESPACE) --context $(CONTEXT) --tail=50

## Delete the completed TrainJob and its pods.
clean:
	kubectl delete trainjob $(JOB_NAME) -n $(NAMESPACE) --context $(CONTEXT) --ignore-not-found
