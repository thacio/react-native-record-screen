// src/index.tsx
import { NativeModules, Dimensions } from 'react-native';

export const RecordingResult = {
  Started: 'started',
  PermissionError: 'permission_error',
} as const;

export type RecordingStartResponse =
  (typeof RecordingResult)[keyof typeof RecordingResult];

export type RecordScreenConfigType = {
  fps?: number;
  bitrate?: number;
  mic?: boolean;
  audioOnly?: boolean;
  broadcast: true
};

export type RecordingSuccessResponse = {
  status: 'success';
  result: {
    outputURL: string;
    audioURL?: string; // Optional audio URL when recording video
  };
};

export type RecordingErrorResponse = {
  status: 'error';
  result: unknown;
};

export type RecordingResponse =
  | RecordingSuccessResponse
  | RecordingErrorResponse;

type RecordScreenNativeModule = {
  setup(
    config: RecordScreenConfigType & { width: number; height: number }
  ): void;
  startRecording(): Promise<RecordingStartResponse>;
  stopRecording(): Promise<RecordingResponse>;
  clean(): Promise<string>;
};

const { RecordScreen } = NativeModules;

const RS = RecordScreen as RecordScreenNativeModule;

class ReactNativeRecordScreenClass {
  private setup(config: RecordScreenConfigType = {}): void {
    const { width, height } = Dimensions.get('window');
    RS.setup({
      mic: true,
      audioOnly: false,
      width,
      height,
      fps: 60,
      bitrate: 1920 * 1080 * 144,
      ...config,
    });
  }

  startRecording(config: RecordScreenConfigType = {}) {
    this.setup(config);
    return RS.startRecording();
  }

  stopRecording() {
    return RS.stopRecording();
  }

  clean() {
    return RS.clean();
  }
}

const ReactNativeRecordScreen = new ReactNativeRecordScreenClass();

export default ReactNativeRecordScreen;
