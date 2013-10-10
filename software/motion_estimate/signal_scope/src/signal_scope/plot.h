#ifndef _PLOT_H_
#define _PLOT_H_

#include <qwt_plot.h>
#include <qwt_interval.h>
#include <qwt_system_clock.h>

class QwtPlotCurve;
class QwtPlotMarker;
class QwtPlotGrid;
class QwtPlotDirectPainter;

class SignalData;
class MyMagnifier;

class Plot: public QwtPlot
{
    Q_OBJECT

public:
    Plot(QWidget * = NULL);
    virtual ~Plot();

    void start();
    void stop();

    virtual void replot();

    void addSignal(SignalData* signalData, QColor color);
    void removeSignal(SignalData* signalData);
    void setSignalVisible(SignalData* signalData, bool visible);
    void setSignalColor(SignalData* signalData, QColor color);

    double timeWindow();

    void setEndTime(double endTime);
    void moveCanvas(int dx, int dy);

    void setBackgroundColor(QString color);

    bool isStopped();

    void flagAxisSyncRequired();

    void setPointSize(double pointSize);

signals:

    void syncXAxisScale(double x0, double x1);

public Q_SLOTS:
    void setTimeWindow(double);
    void setYScale(double);

protected:

    void updateTicks();

private:
    void initBackground();

    QwtPlotMarker *d_origin;
    QwtPlotGrid *d_grid;
    MyMagnifier *mMagnifier;

    bool mStopped;
    bool mAxisSyncRequired;
    int mColorMode;
    double mTimeWindow;

    QMap<SignalData*, QwtPlotCurve*> mSignals;
};

#endif
